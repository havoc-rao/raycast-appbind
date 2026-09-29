// Compare the two independent validators through a safe disabled-execute request.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { validateConfig } from "../raycast/src/config";
const base = JSON.parse(readFileSync(new URL("../examples/config.v1.json", import.meta.url), "utf8"));
const binary = fileURLToPath(new URL("../helper/.build/debug/appbind-helper", import.meta.url));
const cases: Array<[string, boolean, (c: any) => void]> = [
  ["shared example", true, () => {}],
  ["unknown config field", false, c => c.extra = true],
  ["unknown binding field", false, c => c.bindings[0].extra = true],
  ["schema boolean", false, c => c.schemaVersion = true],
  ["future schema", false, c => c.schemaVersion = 2],
  ["enabled number", false, c => c.bindings[0].enabled = 1],
  ["offset boolean", false, c => c.bindings[0].action.offset.x = true],
  ["offset string", false, c => c.bindings[0].action.offset.x = "1"],
  ["offset null", false, c => c.bindings[0].action.offset.x = null],
  ["offset too large", false, c => c.bindings[0].action.offset.x = 100001],
  ["negative offset limit", true, c => c.bindings[0].action.offset.x = -100000],
  ["id trailing newline", false, c => c.bindings[0].id += "\n"],
  ["bundle trailing newline", false, c => c.bindings[0].application.bundleId += "\n"],
  ["key trailing newline", false, c => c.bindings[0].trigger.key += "\n"],
  ["empty modifiers", false, c => c.bindings[0].trigger.modifiers = []],
  ["duplicate modifiers", false, c => c.bindings[0].trigger.modifiers = ["control", "control"]],
  ["disable restore", false, c => c.bindings[0].action.restoreCursor = false],
  ["invalid anchor", false, c => c.bindings[0].action.anchor = "middle"],
  ["blank name", false, c => c.bindings[0].name = " "],
  ["BOM-trimmed name", false, c => c.bindings[0].name = "\uFEFFname"],
  ["NEL nontrim name", true, c => c.bindings[0].name = "\u0085name"],
  ["long utf16 name", false, c => c.bindings[0].name = "😀".repeat(61)],
  ["valid utf16 boundary", true, c => c.bindings[0].name = "😀".repeat(60)],
  ["same app reordered hotkey", false, c => { const b = structuredClone(c.bindings[0]); b.id = "second"; b.trigger.modifiers.reverse(); c.bindings.push(b); }],
  ["different app same hotkey", true, c => { const b = structuredClone(c.bindings[0]); b.id = "second"; b.application.bundleId = "com.example.other"; c.bindings.push(b); }],
];
for (const [name, valid, mutate] of cases) {
  const config = structuredClone(base); mutate(config);
  let tsValid = true;
  try { validateConfig(config); } catch { tsValid = false; }
  assert.equal(tsValid, valid, `TypeScript: ${name}`);
  const result = spawnSync(binary, [], { input: JSON.stringify({protocolVersion: 1, command: "execute", config, bindingId: "toggle-sidebar"}), encoding: "utf8", timeout: 5000 });
  assert.equal(result.error, undefined);
  assert.equal(result.status, 1);
  const response = JSON.parse(result.stdout);
  assert.equal(response.ok, false);
  assert.equal(response.error.code, valid ? "SAFETY_NOT_IMPLEMENTED" : name === "future schema" ? "UNSUPPORTED_VERSION" : "INVALID_CONFIG", `Swift: ${name}: ${result.stdout}`);
}
console.log(`PASS ${cases.length} cross-language config parity cases. Execute always refused; no events posted.`);
