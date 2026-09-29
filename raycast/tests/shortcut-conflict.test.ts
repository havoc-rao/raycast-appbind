import { test } from "node:test";
import assert from "node:assert/strict";
import { Binding, Config } from "../src/config";
import { findShortcutConflict } from "../src/shortcut";

const binding: Binding = {
  id: "sidebar", name: "侧栏", enabled: false,
  application: { bundleId: "com.example.app" },
  trigger: { type: "hotkey", scope: "frontmost-app", key: "k", modifiers: ["option", "control"] },
  action: { type: "window-relative-click", window: "focused", anchor: "top-left", offset: { x: 1, y: 1 }, button: "left", restoreCursor: true },
};
const config: Config = { schemaVersion: 1, bindings: [binding] };
const candidate = { key: "k", modifiers: ["control", "option"] as const };
test("recorded shortcut conflicts include disabled bindings and ignore modifier order", () => {
  assert.equal(findShortcutConflict(config, "com.example.app", candidate), binding);
});
test("editing same binding and other apps can reuse shortcuts", () => {
  assert.equal(findShortcutConflict(config, "com.example.app", candidate, "sidebar"), undefined);
  assert.equal(findShortcutConflict(config, "com.other.app", candidate), undefined);
  assert.equal(findShortcutConflict(config, "com.example.app", { ...candidate, key: "j" }), undefined);
  assert.equal(findShortcutConflict(config, "com.example.app", { key: "k", modifiers: ["control"] }), undefined);
});
