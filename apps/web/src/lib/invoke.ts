import { supabase } from "./supabase.ts";

/**
 * Invoke an Edge Function and return its JSON. supabase-js wraps a non-2xx
 * response in a generic "Edge Function returned a non-2xx status code" error
 * that hides the body, so on an error we read the body and surface OUR message
 * (`{ error }`) instead, which is what tells the user what actually went wrong.
 */
export async function invokeEdge<T = unknown>(
  name: string,
  body: Record<string, unknown>,
): Promise<T> {
  const { data, error } = await supabase!.functions.invoke(name, { body });
  if (error) {
    let message = error.message;
    const ctx = (error as { context?: unknown }).context;
    if (ctx && typeof (ctx as Response).json === "function") {
      try {
        const parsed = await (ctx as Response).json();
        if (parsed?.error) message = String(parsed.error);
      } catch {
        /* body was not JSON; keep the generic message */
      }
    }
    throw new Error(message);
  }
  if (!(data as { ok?: boolean })?.ok) {
    throw new Error((data as { error?: string })?.error ?? "request failed");
  }
  return data as T;
}
