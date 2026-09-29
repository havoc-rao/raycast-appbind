import test from "node:test";
import assert from "node:assert/strict";
import { resolveActiveApplication } from "../src/active-app";

test("active application resolves bundle identity without window/AX access", async () => {
  assert.deepEqual(await resolveActiveApplication(async () => ({ name: "Safari", bundleId: "com.apple.Safari" })), { name: "Safari", bundleId: "com.apple.Safari" });
});
test("Raycast and invalid identities fail closed", async () => {
  for (const app of [{ name: "Raycast", bundleId: "com.example.app" }, { bundleId: "com.raycast.macos" }, { bundleId: "com.raycast" }, {}, { bundleId: "com.app\n" }, { bundleId: "invalid" }]) {
    await assert.rejects(resolveActiveApplication(async () => app));
  }
});
test("missing display name uses bundle ID and provider errors remain visible", async () => {
  assert.deepEqual(await resolveActiveApplication(async () => ({ bundleId: "com.example.app" })), { name: "com.example.app", bundleId: "com.example.app" });
  await assert.rejects(resolveActiveApplication(async () => { throw new Error("query failed"); }), /query failed/);
});
