// The automation status pill — on every screen (DESIGN_SYSTEM §4). Icon + text
// + colour, never colour alone, so it reads in greyscale and for colour-blind
// users. The icon is decorative; the text carries the meaning.
const LABELS = {
  active: { icon: "●", text: "Active", cls: "pill-active" },
  paused: { icon: "‖", text: "Paused", cls: "pill-paused" },
  attention: { icon: "▲", text: "Needs attention", cls: "pill-attention" },
} as const;

export type AutomationState = keyof typeof LABELS;

export function StatusPill({ state }: { state: AutomationState }) {
  const { icon, text, cls } = LABELS[state];
  return (
    <span className={`pill ${cls}`} role="status">
      <span aria-hidden="true">{icon}</span>
      {text}
    </span>
  );
}
