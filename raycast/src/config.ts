export const MAX_BYTES = 1024 * 1024;
export const modifiers = ["control", "option", "shift", "command"] as const;
export const anchors = ["top-left", "top-right", "bottom-left", "bottom-right", "center"] as const;
export type Anchor = (typeof anchors)[number];
export type Modifier = (typeof modifiers)[number];
export interface Binding {
  id: string; name: string; enabled: boolean;
  application: { bundleId: string };
  trigger: { type: "hotkey"; key: string; modifiers: Modifier[]; scope: "frontmost-app" };
  action: { type: "window-relative-click"; window: "focused"; anchor: (typeof anchors)[number]; offset: { x: number; y: number }; button: "left"; restoreCursor: true };
}
export interface Config { schemaVersion: 1; bindings: Binding[] }
export function record(value: unknown): value is Record<string, unknown> { return typeof value === "object" && value !== null && !Array.isArray(value); }
export function exact(value: unknown, keys: string[], path: string): asserts value is Record<string, unknown> {
  if (!record(value) || Object.keys(value).length !== keys.length || keys.some(k => !Object.hasOwn(value, k))) throw new Error(`${path}: missing or unknown fields`);
}
function check(ok: unknown, message: string): asserts ok { if (!ok) throw new Error(message); }
export function validateConfig(input: unknown): Config {
  exact(input, ["schemaVersion", "bindings"], "config");
  check(input.schemaVersion === 1, "Unsupported schemaVersion (expected 1)");
  check(Array.isArray(input.bindings) && input.bindings.length <= 1000, "bindings must be an array of at most 1000 entries");
  const ids = new Set<string>(), hotkeys = new Set<string>();
  for (const b of input.bindings) {
    exact(b, ["id", "name", "enabled", "application", "trigger", "action"], "binding");
    check(typeof b.id === "string" && /^[a-z0-9][a-z0-9-]{0,63}$(?![\s\S])/.test(b.id), "Invalid binding id");
    check(!ids.has(b.id), "Duplicate binding id"); ids.add(b.id);
    check(typeof b.name === "string" && b.name.trim() === b.name && b.name.length > 0 && b.name.length <= 120, "Name must be trimmed and 1–120 characters");
    check(typeof b.enabled === "boolean", "enabled must be boolean");
    exact(b.application, ["bundleId"], "application");
    check(typeof b.application.bundleId === "string" && b.application.bundleId.length <= 255 && /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$(?![\s\S])/.test(b.application.bundleId), "Invalid bundleId");
    exact(b.trigger, ["type", "key", "modifiers", "scope"], "trigger");
    check(b.trigger.type === "hotkey" && b.trigger.scope === "frontmost-app", "Unsupported trigger");
    check(typeof b.trigger.key === "string" && /^[a-z0-9]$(?![\s\S])/.test(b.trigger.key), "Key must be one lowercase ASCII letter or digit");
    check(Array.isArray(b.trigger.modifiers) && b.trigger.modifiers.length > 0 && b.trigger.modifiers.every(m => modifiers.includes(m)) && new Set(b.trigger.modifiers).size === b.trigger.modifiers.length, "Modifiers must be a nonempty unique supported set");
    const hotkey = JSON.stringify([b.application.bundleId, b.trigger.key, [...b.trigger.modifiers].sort()]);
    check(!hotkeys.has(hotkey), "Duplicate same-app hotkey (including disabled bindings)"); hotkeys.add(hotkey);
    exact(b.action, ["type", "window", "anchor", "offset", "button", "restoreCursor"], "action");
    check(b.action.type === "window-relative-click" && b.action.window === "focused" && b.action.button === "left" && b.action.restoreCursor === true && anchors.includes(b.action.anchor as Binding["action"]["anchor"]), "Unsupported action or safety setting");
    exact(b.action.offset, ["x", "y"], "offset");
    for (const n of [b.action.offset.x, b.action.offset.y]) check(typeof n === "number" && Number.isFinite(n) && Math.abs(n) <= 100000, "Offset must be finite with absolute value ≤100000");
  }
  check(Buffer.byteLength(JSON.stringify(input), "utf8") <= MAX_BYTES, "Config exceeds 1 MiB");
  return input as unknown as Config;
}
export function parseConfig(bytes: Buffer): Config {
  check(bytes.length <= MAX_BYTES, "Config exceeds 1 MiB");
  return validateConfig(JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)));
}
export const emptyConfig = (): Config => ({ schemaVersion: 1, bindings: [] });
/** Offsets are persisted with two decimal places; applies to auto-filled and manual values alike. */
export const round2 = (v: number): number => Math.round(v * 100) / 100;
