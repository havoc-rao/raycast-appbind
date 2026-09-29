import { Modifier, modifiers } from "./config";
import { formatShortcut } from "./shortcut";

export type PickerShortcut = { key: string; modifiers: Modifier[] };

/** Stable key-first, modifier-bitmask order; no unmodified shortcuts. */
export const pickerShortcuts: PickerShortcut[] = [..."abcdefghijklmnopqrstuvwxyz0123456789"].flatMap(key =>
  Array.from({ length: (1 << modifiers.length) - 1 }, (_, index) => ({
    key,
    modifiers: modifiers.filter((_, bit) => (index + 1) & (1 << bit)),
  })),
);

const aliases: Record<string, Modifier> = {
  cmd: "command", command: "command", meta: "command", "⌘": "command",
  ctrl: "control", control: "control", "⌃": "control",
  alt: "option", option: "option", opt: "option", "⌥": "option",
  shift: "shift", "⇧": "shift",
};

/** Search is token-based, not fuzzy: malformed or ambiguous input matches nothing. */
export function searchShortcuts(query: string): PickerShortcut[] {
  const normalized = query.trim().toLowerCase();
  if (!normalized) return [...pickerShortcuts];

  // Preserve empty '+' operands so typos such as Ctrl++K cannot broaden a search.
  const operands = normalized.split("+");
  if (operands.some(part => !part.trim())) return [];
  const tokens = operands.join(" ").replace(/[⌘⌃⌥⇧]/g, " $& ").trim().split(/\s+/);
  const selected: Modifier[] = [];
  let key: string | undefined;
  for (const token of tokens) {
    if (Object.hasOwn(aliases, token)) {
      const modifier = aliases[token];
      if (selected.includes(modifier)) return [];
      selected.push(modifier);
    } else if (/^[a-z0-9]$/.test(token) && key === undefined) {
      key = token;
    } else {
      return [];
    }
  }

  const exact = key === undefined ? undefined : formatShortcut({ key, modifiers: selected });
  return pickerShortcuts
    .filter(shortcut => (key === undefined || shortcut.key === key)
      && selected.every(modifier => shortcut.modifiers.includes(modifier)))
    .sort((a, b) => {
      const exactOrder = Number(formatShortcut(b) === exact) - Number(formatShortcut(a) === exact);
      // Array.sort is stable: equally specific results retain catalogue order.
      return exactOrder || a.modifiers.length - b.modifiers.length;
    });
}

/** Raw input matters here: even whitespace pauses keyboard capture. */
export function captureEnabled(query: string): boolean {
  return query.length === 0;
}
