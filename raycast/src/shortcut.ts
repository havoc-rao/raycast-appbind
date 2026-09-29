import { Binding, Config, Modifier, modifiers } from "./config";

const labels: Record<Modifier, string> = { control: "Ctrl", option: "Alt", shift: "Shift", command: "Cmd" };
export function findShortcutConflict(config: Config, bundleId: string, shortcut: { key: string; modifiers: readonly Modifier[] }, editingId?: string): Binding | undefined {
  return config.bindings.find(binding => binding.id !== editingId && binding.application.bundleId === bundleId
    && binding.trigger.key === shortcut.key && formatShortcut(binding.trigger) === formatShortcut(shortcut));
}

const aliases: Record<string, Modifier> = { ctrl: "control", control: "control", alt: "option", option: "option", shift: "shift", cmd: "command", command: "command", meta: "command" };

export function formatShortcut(shortcut: { key: string; modifiers: readonly Modifier[] }): string {
  return [...modifiers.filter(m => shortcut.modifiers.includes(m)).map(m => labels[m]), shortcut.key.toUpperCase()].join("+");
}

export function parseShortcut(text: string): { key: string; modifiers: Modifier[] } {
  const parts = text.trim().toLowerCase().split("+").map(p => p.trim());
  const key = parts.pop() ?? "";
  if (!/^[a-z0-9]$/.test(key) || parts.length === 0) throw new Error("请输入组合键，例如 Ctrl+Alt+K（至少一个修饰键 + A–Z / 0–9）");
  const selected = parts.map(p => Object.hasOwn(aliases, p) ? aliases[p] : undefined);
  if (selected.some(m => !m) || new Set(selected).size !== selected.length) throw new Error("修饰键仅支持 Ctrl、Alt、Shift、Cmd，且不能重复");
  return { key, modifiers: modifiers.filter(m => selected.includes(m)) };
}
