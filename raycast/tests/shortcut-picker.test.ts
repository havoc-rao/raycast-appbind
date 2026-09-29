import { test } from "node:test";
import assert from "node:assert/strict";
import { Modifier, modifiers } from "../src/config";
import { formatShortcut } from "../src/shortcut";
import { captureEnabled, pickerShortcuts, searchShortcuts } from "../src/shortcut-picker-model";

const keys = [..."abcdefghijklmnopqrstuvwxyz0123456789"];
const aliasGroups: [Modifier, string[]][] = [
  ["command", ["cmd", "command", "meta", "⌘"]],
  ["control", ["ctrl", "control", "⌃"]],
  ["option", ["alt", "option", "opt", "⌥"]],
  ["shift", ["shift", "⇧"]],
];

test("catalogue contains exactly 540 unique canonical supported shortcuts", () => {
  assert.equal(pickerShortcuts.length, 540);
  assert.equal(new Set(pickerShortcuts.map(formatShortcut)).size, 540);
  assert.deepEqual([...new Set(pickerShortcuts.map(s => s.key))], keys);
  for (const key of keys) {
    const candidates = pickerShortcuts.filter(s => s.key === key);
    assert.equal(candidates.length, 15);
    for (let mask = 1; mask < 16; mask++) {
      assert.deepEqual(candidates[mask - 1], {
        key, modifiers: modifiers.filter((_, bit) => mask & (1 << bit)),
      });
    }
  }
  assert.notEqual(pickerShortcuts[0].modifiers, pickerShortcuts[15].modifiers);
});

test("empty and whitespace-only searches return the entire catalogue in original order", () => {
  for (const query of ["", " ", "\t\n", "  \u00a0 "]) {
    const result = searchShortcuts(query);
    assert.deepEqual(result, pickerShortcuts);
    assert.notEqual(result, pickerShortcuts);
  }
});

test("every letter and digit alone matches its 15 combinations, irrespective of case", () => {
  for (const key of keys) {
    const result = searchShortcuts(`  ${key.toUpperCase()}  `);
    assert.equal(result.length, 15);
    assert.ok(result.every(s => s.key === key));
    assert.deepEqual(result.map(s => s.modifiers.length), [1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 4]);
  }
});

for (const [modifier, aliases] of aliasGroups) {
  test(`all ${modifier} aliases match modifier supersets, with and without a key`, () => {
    for (const alias of aliases) {
      for (const spelling of [alias, alias.toUpperCase()]) {
        const allKeys = searchShortcuts(` ${spelling} `);
        assert.equal(allKeys.length, 36 * 8);
        assert.ok(allKeys.every(s => s.modifiers.includes(modifier)));
        assert.equal(new Set(allKeys.map(s => s.key)).size, 36);
        for (const separator of [" ", "+", " + ", "\t"]) {
          const result = searchShortcuts(`${spelling}${separator}K`);
          assert.equal(result.length, 8);
          assert.deepEqual(result[0], { key: "k", modifiers: [modifier] });
          assert.ok(result.every(s => s.key === "k" && s.modifiers.includes(modifier)));
          assert.deepEqual(result, searchShortcuts(`${modifier} k`));
        }
      }
    }
  });
}

test("mixed aliases, separators, modifier order and adjacent symbols normalize consistently", () => {
  const expected = searchShortcuts("ctrl+alt+k");
  assert.equal(expected.length, 4);
  assert.deepEqual(expected.map(formatShortcut), [
    "Ctrl+Alt+K", "Ctrl+Alt+Shift+K", "Ctrl+Alt+Cmd+K", "Ctrl+Alt+Shift+Cmd+K",
  ]);
  for (const query of ["⌃⌥K", "  ⌥⌃k  ", "CONTROL option K", "opt + Ctrl k", "k ctrl alt", "⌃+⌥K", "ctrl⌥K", "k⌃⌥"]) {
    assert.deepEqual(searchShortcuts(query), expected, query);
  }
  assert.deepEqual(searchShortcuts("⌘⇧⌥⌃9"), [{ key: "9", modifiers: [...modifiers] }]);
  assert.equal(searchShortcuts("ctrl opt shift").length, 36 * 2);
  assert.equal(searchShortcuts("⌃⌥⇧⌘").length, 36);
});

test("every exact shortcut ranks first and all other matches are stable modifier supersets", () => {
  const before = JSON.stringify(pickerShortcuts);
  for (const shortcut of pickerShortcuts) {
    const result = searchShortcuts(formatShortcut(shortcut));
    assert.deepEqual(result[0], shortcut);
    assert.equal(result.length, 2 ** (4 - shortcut.modifiers.length));
    const expected = pickerShortcuts.filter(s => s.key === shortcut.key
      && shortcut.modifiers.every(m => s.modifiers.includes(m)))
      .sort((a, b) => a.modifiers.length - b.modifiers.length);
    assert.deepEqual(result, expected);
    assert.deepEqual(searchShortcuts(formatShortcut(shortcut)), result);
  }
  assert.equal(JSON.stringify(pickerShortcuts), before);
});

test("modifier-only results preserve catalogue order when specificity ties", () => {
  const result = searchShortcuts("command");
  const expected = pickerShortcuts.filter(s => s.modifiers.includes("command"))
    .sort((a, b) => a.modifiers.length - b.modifiers.length);
  assert.deepEqual(result, expected);
  assert.deepEqual(result.slice(0, 36).map(s => s.key), keys);
});

test("duplicate canonical modifiers are invalid even when aliases differ", () => {
  for (const [, aliases] of aliasGroups) {
    for (const first of aliases) {
      for (const second of aliases) {
        for (const suffix of ["", " k"]) {
          assert.deepEqual(searchShortcuts(`${first}+${second}${suffix}`), []);
        }
      }
    }
  }
  assert.deepEqual(searchShortcuts("⌃⌃K"), []);
});

test("unknown tokens, multiple main keys and malformed separators match nothing", () => {
  for (const query of [
    "unknown", "super+k", "fn k", "cmd unknown k", "cmdk", "controloptionk",
    "k k", "k+l", "ctrl k k", "ctrl k 1", "kk", "12", "cmd+enter", "f1", "é", "💡",
    "cmd++k", "cmd+ +k", "cmd+\t+k", "++", "+", "+k", "k+", "ctrl+", "⌃++⌥K",
    "ctrl,k", "ctrl-k", "ctrl/k", "ctrl.k", "__proto__", "constructor", "toString", "cmd+constructor+k",
  ]) {
    assert.deepEqual(searchShortcuts(query), [], query);
  }
});

test("capture requires literally empty raw input, not normalized empty input", () => {
  assert.equal(captureEnabled(""), true);
  for (const query of [" ", "\t", "\n", "\u00a0", "k", "cmd", "???", "⌃⌥K"]) {
    assert.equal(captureEnabled(query), false, JSON.stringify(query));
  }
});
