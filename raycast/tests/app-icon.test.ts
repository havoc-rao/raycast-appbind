import test from "node:test";
import assert from "node:assert/strict";
import { resolveAppPath, appNameFromPath } from "../src/app-icon";

function fakeRun(results: Array<{ cmd: string; args: string[]; status: number; stdout: string }>) {
  let calls = 0;
  return (cmd: string, args: string[]): { status: number; stdout: string } => {
    const r = results[calls++];
    assert.equal(cmd, r.cmd, `unexpected command ${cmd}`);
    assert.deepEqual(args, r.args, `unexpected args for ${cmd}`);
    return { status: r.status, stdout: r.stdout };
  };
}

test("resolveAppPath finds an indexed app via mdfind and skips lsappinfo", async () => {
  const run = fakeRun([
    { cmd: "/usr/bin/mdfind", args: ["kMDItemCFBundleIdentifier == 'com.apple.Safari'"], status: 0, stdout: "/Applications/Safari.app\n" },
  ]);
  assert.equal(await resolveAppPath("com.apple.Safari", run), "/Applications/Safari.app");
});

test("resolveAppPath falls back to lsappinfo when mdfind finds nothing (running dev app)", async () => {
  const run = fakeRun([
    { cmd: "/usr/bin/mdfind", args: ["kMDItemCFBundleIdentifier == 'com.deepseek.harness.dev.40a33e528d9b'"], status: 0, stdout: "" },
    { cmd: "/usr/bin/lsappinfo", args: ["list"], status: 0, stdout: "1) \"Harness Dev\" ASN:0x0-0x1:\n    bundleID=\"com.deepseek.harness.dev.40a33e528d9b\"\n    bundle path=\"/Users/x/Harness Dev.app\"\n    executable path=\"/Users/x/Harness Dev.app/Contents/MacOS/Electron\"\n" },
  ]);
  assert.equal(await resolveAppPath("com.deepseek.harness.dev.40a33e528d9b", run), "/Users/x/Harness Dev.app");
});

test("resolveAppPath returns undefined when neither source resolves", async () => {
  const run = fakeRun([
    { cmd: "/usr/bin/mdfind", args: ["kMDItemCFBundleIdentifier == 'com.example.missing'"], status: 0, stdout: "" },
    { cmd: "/usr/bin/lsappinfo", args: ["list"], status: 0, stdout: "1) \"Other\" ASN:0x0-0x1:\n    bundleID=\"com.apple.Other\"\n" },
  ]);
  assert.equal(await resolveAppPath("com.example.missing", run), undefined);
});

test("resolveAppPath rejects malformed ids without spawning anything", async () => {
  const run = () => { throw new Error("must not spawn"); };
  assert.equal(await resolveAppPath("com.app\n", run), undefined);
  assert.equal(await resolveAppPath("", run), undefined);
});

test("appNameFromPath strips the .app suffix and falls back", () => {
  assert.equal(appNameFromPath("/Applications/Safari.app", "x"), "Safari");
  assert.equal(appNameFromPath("/Users/x/Harness Dev.app", "x"), "Harness Dev");
  assert.equal(appNameFromPath("", "com.example.x"), "com.example.x");
});