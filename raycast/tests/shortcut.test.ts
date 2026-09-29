import { test } from "node:test";
import assert from "node:assert/strict";
import { defaultTimeoutMs, parseResponse, timeoutCapMs, validateRequest } from "../src/transport";

import { formatShortcut, parseShortcut } from "../src/shortcut";
import { modifiers } from "../src/config";

test("unified shortcut input round-trips all supported combinations", () => {
  for (const key of "abcdefghijklmnopqrstuvwxyz0123456789") {
    for (let mask = 1; mask < 16; mask++) {
      const shortcut = { key, modifiers: modifiers.filter((_, index) => mask & (1 << index)) };
      assert.deepEqual(parseShortcut(formatShortcut(shortcut)), shortcut);
    }
  }
  assert.equal(formatShortcut(parseShortcut(" command + OPTION + Control + k ")), "Ctrl+Alt+Cmd+K");
  assert.equal(formatShortcut(parseShortcut("meta+shift+9")), "Shift+Cmd+9");
});

test("unified shortcut input rejects malformed and ambiguous shortcuts", () => {
  for (const text of ["", "K", "Ctrl", "Ctrl+", "Ctrl++K", "Ctrl+Ctrl+K", "Ctrl+Control+K", "Fn+K", "Ctrl+F1", "Ctrl+K Ctrl+C", "Ctrl+é", "Ctrl+KK", "K+Ctrl"]) {
    assert.throws(() => parseShortcut(text), text);
  }
});

const request = { protocolVersion: 1, command: "record-shortcut" };
const parse = (data: unknown, exitCode = 0) => parseResponse(Buffer.from(JSON.stringify({ protocolVersion: 1, ok: true, data }) + "\n"), "record-shortcut", exitCode);

test("shortcut recording accepts only the explicit parameterless request", () => {
  validateRequest(request);
  for (const extra of [{ bundleId: "com.example.app" }, { key: "k" }, { config: {} }, { protocolVersion: 2 }]) {
    assert.throws(() => validateRequest({ ...request, ...extra }));
  }
});

test("shortcut recording validates keys and modifier combinations before form refill", () => {
  for (const key of ["a", "z", "0", "9"]) {
    const data = { key, modifiers: ["control", "option", "shift", "command"] };
    const result = parse(data);
    assert.equal(result.ok, true);
    if (result.ok) assert.deepEqual(result.data, data);
  }
  for (const key of ["", "K", "F1", "é", "k\n", "ab", 1, null]) assert.throws(() => parse({ key, modifiers: ["control"] }));
  for (const modifiers of [[], ["fn"], ["control", "control"], [null], "command", null]) assert.throws(() => parse({ key: "k", modifiers }));
  assert.throws(() => parse({ key: "k" }));
  assert.throws(() => parse({ key: "k", modifiers: ["control"], extra: true }));
  assert.throws(() => parse({ key: "k", modifiers: ["control"] }, 1));
});

test("shortcut cancellation is not a success payload and allows human interaction time", () => {
  const cancelled = { protocolVersion: 1, ok: false, error: { code: "USER_CANCELLED", message: "Recording cancelled" } };
  const result = parseResponse(Buffer.from(JSON.stringify(cancelled) + "\n"), "record-shortcut", 1);
  assert.equal(result.ok, false);
  assert.equal(defaultTimeoutMs("record-shortcut"), 150000);
  assert.equal(timeoutCapMs("record-shortcut"), 150000);
});
