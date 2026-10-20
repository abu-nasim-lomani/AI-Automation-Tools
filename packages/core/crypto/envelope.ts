/**
 * Envelope encryption for tenant credentials.
 *
 * Source of truth: docs/SECURITY.md §5 (frozen). Deliberately NOT Supabase
 * Vault: Vault's own docs warn that anyone with access to the decrypted view
 * has access to decrypted secrets, and the project root key is retrievable via
 * the Management API. We want the decryption boundary OUTSIDE the database, so
 * that a full database compromise yields ciphertext only (ADR-006).
 *
 * Scheme:
 *   master key   32 random bytes, per key_version, held only in the function
 *                environment. Never in the database, the repo, or a log.
 *   per-tenant   HKDF-SHA256(master, salt = org_id bytes, info = "cred:v1")
 *   cipher       AES-256-GCM, fresh 96-bit IV per seal, 128-bit tag
 *   AAD          org_id : credential_id : key_version
 *
 * The AAD binding is the point: moving a ciphertext blob to a different row or
 * a different org makes decryption FAIL rather than succeed under the wrong
 * tenant.
 *
 * Uses only WebCrypto, so it runs unchanged on Deno (Edge Functions) and Node.
 * Accepted limitation (SECURITY.md R-A1): a compromised runtime holding the
 * master key can decrypt everything. There is no $0 way around that — something
 * must hold the key to use the credential.
 */

const HKDF_INFO = new TextEncoder().encode("cred:v1");
const IV_BYTES = 12; // 96-bit, the AES-GCM recommendation
const MASTER_KEY_BYTES = 32;

export interface SealedCredential {
  /** AES-256-GCM output with the 128-bit tag appended. Stored as bytea. */
  ciphertext: Uint8Array;
  /** 96-bit nonce, unique per seal. Stored as bytea. */
  iv: Uint8Array;
  /** Which master key sealed this. Bumped on rotation. */
  keyVersion: number;
  /** Non-secret display value, e.g. "AIza…7f2c". Last 4 characters only. */
  maskedHint: string;
}

export interface CredentialIdentity {
  orgId: string;
  credentialId: string;
}

/** version -> 32 raw bytes. Both the current and retiring keys live here during rotation. */
export type MasterKeyring = ReadonlyMap<number, Uint8Array>;

export class EnvelopeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "EnvelopeError";
  }
}

/** Parse a canonical UUID into its 16 raw bytes, for use as the HKDF salt. */
function uuidBytes(uuid: string): Uint8Array {
  const hex = uuid.replace(/-/g, "");
  if (hex.length !== 32 || /[^0-9a-fA-F]/.test(hex)) {
    throw new EnvelopeError(`not a uuid: ${uuid.slice(0, 8)}…`);
  }
  const out = new Uint8Array(16);
  for (let i = 0; i < 16; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function aad({ orgId, credentialId }: CredentialIdentity, keyVersion: number): Uint8Array {
  return new TextEncoder().encode(`${orgId}:${credentialId}:${keyVersion}`);
}

function masterKey(keyring: MasterKeyring, version: number): Uint8Array {
  const key = keyring.get(version);
  if (!key) {
    throw new EnvelopeError(
      `no master key for version ${version}; a retiring key must stay in the ` +
        `keyring until no row references it`,
    );
  }
  if (key.length !== MASTER_KEY_BYTES) {
    throw new EnvelopeError(
      `master key v${version} is ${key.length} bytes, expected ${MASTER_KEY_BYTES}`,
    );
  }
  return key;
}

/** HKDF the per-tenant data key. Not exported: callers never hold a raw DEK. */
async function deriveDek(
  keyring: MasterKeyring,
  keyVersion: number,
  orgId: string,
): Promise<CryptoKey> {
  const base = await crypto.subtle.importKey(
    "raw",
    masterKey(keyring, keyVersion) as BufferSource,
    "HKDF",
    false,
    ["deriveKey"],
  );
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: uuidBytes(orgId) as BufferSource, info: HKDF_INFO as BufferSource },
    base,
    { name: "AES-GCM", length: 256 },
    false, // non-extractable: the DEK cannot be read back out
    ["encrypt", "decrypt"],
  );
}

/**
 * Non-secret display value. Shows at most the last 4 characters, so a mask can
 * never reconstruct enough of a key to be useful. Short inputs reveal nothing.
 */
export function maskSecret(plaintext: string): string {
  const prefix = plaintext.slice(0, 4);
  const tail = plaintext.length >= 8 ? plaintext.slice(-4) : "";
  return tail ? `${prefix}…${tail}` : "…";
}

/** Encrypt a credential for storage. The plaintext is never returned or logged. */
export async function sealCredential(
  keyring: MasterKeyring,
  keyVersion: number,
  identity: CredentialIdentity,
  plaintext: string,
): Promise<SealedCredential> {
  if (plaintext.length === 0) throw new EnvelopeError("refusing to seal an empty credential");
  const dek = await deriveDek(keyring, keyVersion, identity.orgId);
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const sealed = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: iv as BufferSource, additionalData: aad(identity, keyVersion) as BufferSource, tagLength: 128 },
    dek,
    new TextEncoder().encode(plaintext) as BufferSource,
  );
  return {
    ciphertext: new Uint8Array(sealed),
    iv,
    keyVersion,
    maskedHint: maskSecret(plaintext),
  };
}

/**
 * Decrypt. Throws if the record has been moved to another row or org, if the
 * key version is wrong, or if the ciphertext or tag has been altered — all of
 * which surface as the same authentication failure, by design.
 */
export async function openCredential(
  keyring: MasterKeyring,
  identity: CredentialIdentity,
  record: Pick<SealedCredential, "ciphertext" | "iv" | "keyVersion">,
): Promise<string> {
  if (record.iv.length !== IV_BYTES) {
    throw new EnvelopeError(`iv is ${record.iv.length} bytes, expected ${IV_BYTES}`);
  }
  const dek = await deriveDek(keyring, record.keyVersion, identity.orgId);
  let opened: ArrayBuffer;
  try {
    opened = await crypto.subtle.decrypt(
      {
        name: "AES-GCM",
        iv: record.iv as BufferSource,
        additionalData: aad(identity, record.keyVersion) as BufferSource,
        tagLength: 128,
      },
      dek,
      record.ciphertext as BufferSource,
    );
  } catch {
    // Never echo the cause: it would distinguish "wrong org" from "tampered",
    // which is an oracle.
    throw new EnvelopeError(
      "credential failed authentication: wrong org, wrong row, wrong key version, " +
        "or altered ciphertext",
    );
  }
  return new TextDecoder().decode(opened);
}

/** Read a keyring from the environment. Names only ever hold base64, never a key in code. */
export function keyringFromEnv(
  env: Record<string, string | undefined>,
  versions: readonly number[],
): MasterKeyring {
  const ring = new Map<number, Uint8Array>();
  for (const v of versions) {
    const raw = env[`MASTER_KEY_V${v}`];
    if (!raw) continue;
    const bytes = Uint8Array.from(atob(raw), (c) => c.charCodeAt(0));
    if (bytes.length !== MASTER_KEY_BYTES) {
      throw new EnvelopeError(`MASTER_KEY_V${v} decodes to ${bytes.length} bytes, expected 32`);
    }
    ring.set(v, bytes);
  }
  if (ring.size === 0) throw new EnvelopeError("no master key found in the environment");
  return ring;
}
