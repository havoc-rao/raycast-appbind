// Safe CLI contract smoke tests: never send real clicks or request permissions.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
const binary = fileURLToPath(new URL("../helper/.build/debug/appbind-helper", import.meta.url));
const config = JSON.parse(readFileSync(new URL("../examples/config.v1.json", import.meta.url), "utf8"));
let count = 0;
function request(input, expectedCode) {
  const r = spawnSync(binary, [], { input: typeof input === "string" ? input : JSON.stringify(input), encoding: "utf8", timeout: 5000, maxBuffer: 1024 * 1024 });
  assert.equal(r.error, undefined, r.error?.message);
  const response = JSON.parse(r.stdout);
  assert.equal(response.protocolVersion, 1);
  assert.equal(response.ok, !expectedCode);
  assert.equal(r.status, expectedCode ? 1 : 0);
  if (expectedCode) assert.equal(response.error.code, expectedCode);
  count++;
  return response;
}
const status = request({ protocolVersion: 1, command: "status" });
assert.equal(status.data.executionEnabled, false);
assert.equal(typeof status.data.accessibilityTrusted, "boolean");
request("not JSON", "INVALID_REQUEST");
request({ protocolVersion: 2, command: "status" }, "UNSUPPORTED_VERSION");
request({ protocolVersion: 1, command: "status", surprise: true }, "INVALID_REQUEST");
request({ protocolVersion: 1, command: "execute", config, bindingId: "toggle-sidebar" }, "SAFETY_NOT_IMPLEMENTED");
request({ protocolVersion: 1, command: "execute", config, bindingId: "missing" }, "BINDING_NOT_FOUND");
const disabled = structuredClone(config); disabled.bindings[0].enabled = false;
request({ protocolVersion: 1, command: "execute", config: disabled, bindingId: "toggle-sidebar" }, "BINDING_DISABLED");
const invalid = structuredClone(config); invalid.bindings[0].action.offset.x = null;
request({ protocolVersion: 1, command: "execute", config: invalid, bindingId: "toggle-sidebar" }, "INVALID_CONFIG");
const duplicate = structuredClone(config); duplicate.bindings.push({ ...structuredClone(config.bindings[0]), id: "duplicate" });
request({ protocolVersion: 1, command: "execute", config: duplicate, bindingId: "toggle-sidebar" }, "INVALID_CONFIG");
// capture: malformed requests must be rejected before any overlay appears (no AX hit, no prompt).
request({ protocolVersion: 1, command: "capture" }, "INVALID_REQUEST");
request({ protocolVersion: 1, command: "capture", bundleId: "com.example.app", anchor: "middle" }, "INVALID_REQUEST");
request({ protocolVersion: 1, command: "capture", bundleId: "com.example.app\n", anchor: "top-left" }, "INVALID_REQUEST");
request({ protocolVersion: 1, command: "capture", bundleId: "com.example.app", anchor: "top-left", config }, "INVALID_REQUEST");
console.log(`PASS ${count} safe Helper CLI contract smoke cases; executionEnabled=false. No inspect/click/permission prompts, no overlay on malformed capture.`);
