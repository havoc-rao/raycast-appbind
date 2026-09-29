import { test } from "node:test";
import assert from "node:assert/strict";
import { allProbeShortcuts, sampleShortcuts, probeShortcutId, probeReport } from "../src/shortcut-probe-model";

test("probe generates 540 unique supported combinations containing all sample cases", () => {
  const all = allProbeShortcuts();
  const ids = new Set(all.map(probeShortcutId));
  assert.equal(all.length, 540);
  assert.equal(ids.size, 540);
  for (const shortcut of sampleShortcuts) assert.ok(ids.has(probeShortcutId(shortcut)));
  for (const shortcut of all) {
    assert.match(shortcut.key, /^[a-z0-9]$/);
    assert.ok(shortcut.modifiers.length >= 1 && shortcut.modifiers.length <= 4);
    assert.equal(new Set(shortcut.modifiers).size, shortcut.modifiers.length);
  }
});

test("probe report identifies callback evidence limits and no persistence", () => {
  const report = probeReport("5 combinations", ["MATCH Ctrl+Alt+K"]);
  assert.match(report, /MATCH Ctrl\+Alt\+K/);
  assert.match(report, /menu clicks/);
  assert.match(report, /No bindings were saved/);
});
