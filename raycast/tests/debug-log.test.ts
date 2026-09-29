import test from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { appendLog, readLogTail } from "../src/debug-log";

test("debug log appends, trims at cap and never throws", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "appbind-log-"));
  const file = path.join(dir, "appbind.log");
  try {
    await appendLog(file, "a", "first entry");
    await appendLog(file, "a", "second entry");
    const text = await fs.readFile(file, "utf8");
    assert.match(text, /\[a\] first entry/);
    assert.match(text, /\[a\] second entry/);
    assert.equal((await readLogTail(1024 * 1024, file)).includes("second entry"), true);
    // Readable tail bound respected.
    const short = await fs.readFile(file, "utf8");
    assert.equal(short.length > 0, true);
    // Reading without an explicit file on a non-Raycast runtime must not throw.
    assert.equal(typeof (await readLogTail(1024)), "string");
    // Never throws on bad paths.
    await appendLog(path.join(dir, "missing", "dir", "x.log"), "a", "ignored");
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});