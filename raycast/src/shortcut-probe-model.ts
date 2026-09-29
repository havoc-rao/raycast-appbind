import { Modifier, modifiers } from "./config";
import { formatShortcut } from "./shortcut";

export interface ProbeShortcut { key: string; modifiers: Modifier[] }
export const sampleShortcuts: ProbeShortcut[] = [
  { key: "k", modifiers: ["control", "option"] },
  { key: "k", modifiers: ["command"] },
  { key: "s", modifiers: ["command"] },
  { key: "w", modifiers: ["command"] },
  { key: "k", modifiers: ["shift"] },
];
export function allProbeShortcuts(): ProbeShortcut[] {
  return [..."abcdefghijklmnopqrstuvwxyz0123456789"].flatMap(key =>
    Array.from({ length: 15 }, (_, i) => ({ key, modifiers: modifiers.filter((_, bit) => (i + 1) & (1 << bit)) })),
  );
}
export const probeShortcutId = (shortcut: ProbeShortcut) => formatShortcut(shortcut);
export function probeReport(mode: string, events: readonly string[]): string {
  return `Raycast Action shortcut probe\nMode: ${mode}\nCallbacks (newest first):\n${events.join("\n")}\n\nOnly delivered Action callbacks are recorded. A callback does not prove its source was a keyboard event; menu clicks also invoke it. Missing keys require manual observation. No bindings were saved.`;
}
