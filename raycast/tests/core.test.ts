import { test } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import path from "node:path";
import { Config, parseConfig, round2, validateConfig } from "../src/config";
import { ConfigStore } from "../src/storage";
import { callHelper, parseResponse, validateRequest } from "../src/transport";
const root = path.resolve(__dirname, "..");
async function sample(): Promise<Config> { return parseConfig(await fs.readFile(path.join(root, "../examples/config.v1.json"))); }
async function temporary() { await fs.mkdir(path.join(root, ".test-tmp"), { recursive: true }); return fs.mkdtemp(path.join(root, ".test-tmp/case-")); }
test("shared example and strict nested schema", async () => {
  const c = await sample(); assert.equal(validateConfig(c), c);
  for (const change of [
    (v: any) => v.extra = true, (v: any) => v.schemaVersion = 2,
    (v: any) => v.bindings[0].application.extra = true,
    (v: any) => v.bindings[0].trigger.extra = true,
    (v: any) => v.bindings[0].action.offset.extra = true,
    (v: any) => v.bindings[0].action.restoreCursor = false,
    (v: any) => v.bindings[0].action.offset.x = Infinity,
    (v: any) => v.bindings[0].action.offset.y = NaN,
    (v: any) => v.bindings[0].action.offset.x = 100001,
    (v: any) => v.bindings[0].trigger.modifiers = ["control", "control"],
    (v: any) => v.bindings[0].trigger.modifiers = [],
    (v: any) => v.bindings[0].id += "\n",
    (v: any) => v.bindings[0].application.bundleId += "\n",
    (v: any) => v.bindings[0].trigger.key += "\n",
    (v: any) => v.bindings[0].name = " padded ",
    (v: any) => v.bindings[0].name = "a".repeat(121),
    (v: any) => v.bindings[0].enabled = 1,
  ]) { const v = structuredClone(c); change(v); assert.throws(() => validateConfig(v)); }
  assert.throws(() => parseConfig(Buffer.from([0xff])));
  assert.throws(() => parseConfig(Buffer.alloc(1024 * 1024 + 1)));
});
test("normalized same-app conflicts include disabled; cross-app reuse allowed", async () => {
  const c = await sample(), b = structuredClone(c.bindings[0]); b.id = "second"; b.enabled = false; b.trigger.modifiers.reverse(); c.bindings.push(b);
  assert.throws(() => validateConfig(c), /Duplicate same-app/);
  b.application.bundleId = "com.other.app"; assert.doesNotThrow(() => validateConfig(c));
  b.id = c.bindings[0].id; assert.throws(() => validateConfig(c), /Duplicate binding id/);
});
test("atomic persistence permissions, exclusive locking and no corrupt reset", async () => {
  const dir = await temporary(), store = new ConfigStore(path.join(dir, "support"));
  try {
    assert.deepEqual(await store.read(), { schemaVersion: 1, bindings: [] });
    const c = await sample(); await store.update(() => c);
    assert.equal((await fs.stat(store.directory)).mode & 0o777, 0o700);
    assert.equal((await fs.stat(store.file)).mode & 0o777, 0o600);
    assert.deepEqual(await store.read(), c);
    await fs.writeFile(store.lock, "busy");
    await assert.rejects(store.update(() => ({ schemaVersion: 1, bindings: [] })), /Config busy/);
    assert.deepEqual(await store.read(), c); await fs.unlink(store.lock);
    await assert.rejects(store.update(v => ({ ...v, schemaVersion: 2 } as unknown as Config)));
    assert.deepEqual(await store.read(), c);
    await fs.writeFile(store.file, "broken");
    await assert.rejects(store.update(() => c)); assert.equal(await fs.readFile(store.file, "utf8"), "broken");
    await assert.rejects(fs.stat(store.lock), { code: "ENOENT" });
  } finally { await fs.rm(dir, { recursive: true, force: true }); }
});
test("concurrent writers refuse busy without losing successful update", async () => {
  const dir = await temporary(), store = new ConfigStore(dir), c = await sample();
  try { const results = await Promise.allSettled([store.update(() => c), store.update(() => c)]); assert.equal(results.filter(r => r.status === "fulfilled").length, 1); assert.deepEqual(await store.read(), c); }
  finally { await fs.rm(dir, { recursive: true, force: true }); }
});
test("symlink config refused", async () => {
  const dir = await temporary(), store = new ConfigStore(dir);
  try { await fs.writeFile(path.join(dir, "target"), JSON.stringify(await sample())); await fs.symlink(path.join(dir, "target"), store.file); await assert.rejects(store.read()); await assert.rejects(store.update(() => ({ schemaVersion: 1, bindings: [] }))); }
  finally { await fs.rm(dir, { recursive: true, force: true }); }
});
const success = { protocolVersion: 1, ok: true, data: { helperVersion: "0.1.0", accessibilityTrusted: false, executionEnabled: false } };
test("strict response envelope, payload, exit status and request shape", () => {
  assert.equal(parseResponse(Buffer.from(JSON.stringify(success) + "\n"), "status", 0).ok, true);
  for (const r of [{ ...success, surprise: true }, { ...success, protocolVersion: 2 }, { ...success, error: {} }, { ...success, data: { ...success.data, executionEnabled: true } }, { protocolVersion: 1, ok: false, error: { code: "UNKNOWN", message: "x" } }]) assert.throws(() => parseResponse(Buffer.from(JSON.stringify(r) + "\n"), "status", 0));
  assert.throws(() => parseResponse(Buffer.from(JSON.stringify(success)), "status", 0));
  assert.throws(() => parseResponse(Buffer.from(JSON.stringify(success) + "\n{}\n"), "status", 0));
  assert.throws(() => parseResponse(Buffer.from(JSON.stringify(success) + "\n"), "status", 1));
  assert.throws(() => validateRequest({ protocolVersion: 1, command: "status", config: {} }));
  assert.throws(() => validateRequest({ protocolVersion: 1, command: "execute" }));
});
test("dry-run responses accept large valid targets and reject half-open boundary", () => {
  const response = { protocolVersion: 1, ok: true, data: { bindingId: "test", bundleId: "com.example.app", pid: 123, diagnosticOnly: true, frame: { x: 100000, y: 0, width: 100000, height: 100 }, target: { x: 150000, y: 50 } } };
  assert.equal(parseResponse(Buffer.from(JSON.stringify(response) + "\n"), "dry-run", 0).ok, true);
  response.data.target.x = 200000;
  assert.throws(() => parseResponse(Buffer.from(JSON.stringify(response) + "\n"), "dry-run", 0), /half-open/);
});
test("spawn transport: structured stdin, no shell, missing helper, timeout, caps, invalid output", async () => {
  const dir = await temporary(); let seq = 0;
  async function executable(body: string) { const file = path.join(dir, `helper space ; ${seq++}`); await fs.writeFile(file, `#!${process.execPath}\n${body}`, { mode: 0o700 }); return file; }
  const req = { protocolVersion: 1, command: "status" } as const;
  try {
    const good = await executable(`let s='';process.stdin.on('data',c=>s+=c);process.stdin.on('end',()=>{const r=JSON.parse(s);if(Object.keys(r).sort().join(',')!=='command,protocolVersion')process.exit(9);console.log(${JSON.stringify(JSON.stringify(success))})});`);
    assert.equal((await callHelper(good, req)).ok, true);
    await assert.rejects(callHelper("relative", req), /HELPER_UNAVAILABLE/);
    await assert.rejects(callHelper(path.join(dir, "missing"), req), /HELPER_UNAVAILABLE/);
    await assert.rejects(callHelper(await executable("setInterval(()=>{},1000)"), req, { timeoutMs: 30 }), /HELPER_TIMEOUT/);
    await assert.rejects(callHelper(await executable("process.stdout.write('x'.repeat(10000));setInterval(()=>{},1000)"), req, { maxOutputBytes: 100 }), /INVALID_RESPONSE/);
    await assert.rejects(callHelper(await executable("process.stderr.write('x'.repeat(10000));setInterval(()=>{},1000)"), req, { maxOutputBytes: 100 }), /INVALID_RESPONSE/);
    await assert.rejects(callHelper(await executable("console.log('not JSON')"), req), /INVALID_RESPONSE/);
    const error = { protocolVersion: 1, ok: false, error: { code: "PERMISSION_DENIED", message: "No AX trust" } };
    const denied = await executable(`console.log(${JSON.stringify(JSON.stringify(error))});process.exitCode=1;`);
    assert.deepEqual(await callHelper(denied, req), error);
  } finally { await fs.rm(dir, { recursive: true, force: true }); }
});

test("round2 persists offsets with two decimals", () => {
  assert.equal(round2(801.72265625), 801.72);
  assert.equal(round2(526.7578125), 526.76);
  assert.equal(round2(-42.006), -42.01);
  assert.equal(round2(0), 0);
  assert.equal(round2(100000), 100000);
});
