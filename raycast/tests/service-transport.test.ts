import test from "node:test";
import type { TestContext } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { emptyConfig, MAX_BYTES } from "../src/config";
import { ConfigStore } from "../src/storage";
import { callService, configDigest, parseServiceResponse, ServiceCommand, ServiceState, ServiceTransportError } from "../src/service-transport";

const stopped: ServiceState = {
  running: false, executionEnabled: false, accessibilityTrusted: false, inputMonitoringTrusted: false,
  enabledBindings: 0, configDigest: null, lastError: null, pid: null,
};
const running: ServiceState = {
  running: true, executionEnabled: true, accessibilityTrusted: true, inputMonitoringTrusted: true,
  enabledBindings: 2, configDigest: "a".repeat(64), lastError: null, pid: 123,
};
const reply = (data: unknown = stopped) => JSON.stringify({ ok: true, data }) + "\n";

async function fakeHelper(t: TestContext, body: string) {
  const directory = await mkdtemp(join(tmpdir(), "appbind-service-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const helper = join(directory, "fake helper;literal");
  await writeFile(helper, `#!${process.execPath}\n${body}\n`, { mode: 0o700 });
  return { helper, directory };
}

test("service parser accepts exact running and stopped states, including diagnostic text", () => {
  for (const state of [stopped, running, { ...running, executionEnabled: false, inputMonitoringTrusted: false, configDigest: null, lastError: "Permission missing\n再试" }]) {
    assert.deepEqual(parseServiceResponse(reply(state), 0), state);
    assert.deepEqual(parseServiceResponse(Buffer.from(reply(state)), 0), state);
  }
});

test("service parser rejects framing, UTF-8, size, envelope and exit violations", () => {
  const invalid: Array<[string | Buffer, number | null]> = [
    [reply().trimEnd(), 0], [reply() + "\n", 0], [reply() + reply(), 0], ["log\n" + reply(), 0],
    [reply().replace(/\n$/, "\r\n"), 0], [JSON.stringify({ ok: true, data: stopped }, null, 2) + "\n", 0],
    ["not json\n", 0], ["null\n", 0], ["[]\n", 0], [reply(), 1], [reply(), 2], [reply(), null],
    [JSON.stringify({ protocolVersion: 1, ok: true, data: stopped }) + "\n", 0],
    [JSON.stringify({ ok: "true", data: stopped }) + "\n", 0],
    [JSON.stringify({ ok: true }) + "\n", 0],
    [Buffer.concat([Buffer.from('{"ok":false,"error":{"code":"X","message":"'), Buffer.from([0xff]), Buffer.from('"}}\n')]), 1],
    [" ".repeat(MAX_BYTES) + reply(), 0],
  ];
  for (const [stdout, code] of invalid) assert.throws(() => parseServiceResponse(stdout, code), /INVALID_RESPONSE/);
  const atLimit = " ".repeat(MAX_BYTES - Buffer.byteLength(reply())) + reply();
  assert.deepEqual(parseServiceResponse(atLimit, 0), stopped);
});

test("service parser strictly validates all state fields and cross-field invariants", () => {
  const invalid = [
    ...["running", "executionEnabled", "accessibilityTrusted", "inputMonitoringTrusted"].map(key => ({ ...running, [key]: 1 })),
    ...[-1, 1.5, Number.MAX_SAFE_INTEGER + 1, "1", null].map(enabledBindings => ({ ...running, enabledBindings })),
    ...["A".repeat(64), "a".repeat(63), "a".repeat(65), "a".repeat(64) + "\n", "", 1].map(configDigest => ({ ...running, configDigest })),
    ...[null, 0, -1, 1.5, "123", Number.MAX_SAFE_INTEGER + 1].map(pid => ({ ...running, pid })),
    { ...stopped, pid: 123 }, { ...stopped, executionEnabled: true },
    { ...running, accessibilityTrusted: false }, { ...running, inputMonitoringTrusted: false },
    { ...running, configDigest: null }, { ...running, lastError: false }, { ...running, extra: true },
  ];
  for (const state of invalid) assert.throws(() => parseServiceResponse(reply(state), 0), /INVALID_RESPONSE/);
  for (const key of Object.keys(stopped)) {
    const state: Record<string, unknown> = { ...stopped };
    delete state[key];
    assert.throws(() => parseServiceResponse(reply(state), 0), /INVALID_RESPONSE/);
  }
});

test("service error envelope requires exact string fields and exit 1", () => {
  const error = { code: "SERVICE_UNAVAILABLE", message: "Service is not running" };
  const text = JSON.stringify({ ok: false, error }) + "\n";
  assert.throws(() => parseServiceResponse(text, 1), (e: unknown) => e instanceof ServiceTransportError && e.code === error.code && e.message.includes(error.message));
  for (const code of [0, 2, null]) assert.throws(() => parseServiceResponse(text, code), /INVALID_RESPONSE/);
  for (const bad of [{}, { code: 1, message: "x" }, { code: "x", message: null }, { ...error, extra: true }]) {
    assert.throws(() => parseServiceResponse(JSON.stringify({ ok: false, error: bad }) + "\n", 1), /INVALID_RESPONSE/);
  }
});

test("service client sends only the explicit command and literal directory argv, without shell", async t => {
  const fixture = await fakeHelper(t, `const fs = require('node:fs'); fs.appendFileSync(__filename + '.calls', JSON.stringify(process.argv.slice(2)) + '\\n'); process.stdout.write(${JSON.stringify(reply())});`);
  const directory = join(fixture.directory, "support spaces;$(touch NEVER) 'quotes'");
  for (const command of ["start", "status", "reload", "stop"] as const) assert.deepEqual(await callService(fixture.helper, directory, command), stopped);
  const calls = (await readFile(fixture.helper + ".calls", "utf8")).trim().split("\n").map(line => JSON.parse(line));
  assert.deepEqual(calls, ["start", "status", "reload", "stop"].map(command => [`service-${command}`, "--directory", directory]));
});

test("service client rejects paths and commands before execution, and reports spawn failures", async t => {
  const { helper, directory } = await fakeHelper(t, "process.exit(99);");
  for (const bad of ["", "relative", "~/helper", "/tmp/helper\0bad"]) {
    await assert.rejects(callService(bad, directory, "status"), /INVALID_PATH/);
    await assert.rejects(callService(helper, bad, "status"), /INVALID_PATH/);
  }
  await assert.rejects(callService(helper, directory, "permissions" as ServiceCommand), /INVALID_COMMAND/);
  await assert.rejects(callService(join(directory, "missing"), directory, "status"), /HELPER_UNAVAILABLE/);
});

test("service client rejects malformed output, errors, exit mismatches and signals", async t => {
  const bodies = [
    `process.stdout.write(${JSON.stringify(reply())}); process.exitCode = 1;`,
    `process.stdout.write(${JSON.stringify(reply() + reply())});`,
    `process.stdout.write(${JSON.stringify(JSON.stringify({ ok: false, error: { code: "NO_SERVICE", message: "not running" } }) + "\n")}); process.exitCode = 1;`,
    `process.stdout.write(${JSON.stringify(reply())}); process.kill(process.pid, 'SIGTERM');`,
  ];
  for (const body of bodies) {
    const { helper, directory } = await fakeHelper(t, body);
    await assert.rejects(callService(helper, directory, "status"), /INVALID_RESPONSE|NO_SERVICE/);
  }
});

test("service client bounds combined stdout and stderr without needing process exit", async t => {
  for (const stream of ["stdout", "stderr"]) {
    const { helper, directory } = await fakeHelper(t, `process.${stream}.write('x'.repeat(${MAX_BYTES + 1})); setInterval(() => {}, 1000);`);
    await assert.rejects(callService(helper, directory, "status"), /INVALID_RESPONSE.*1 MiB/);
  }
});

test("service timeouts are 15 seconds for start and 5 seconds for all other commands", { timeout: 22000 }, async t => {
  const { helper, directory } = await fakeHelper(t, "setInterval(() => {}, 1000);");
  await Promise.all((["start", "status", "reload", "stop"] as const).map(async command => {
    const began = Date.now();
    const expected = command === "start" ? 15000 : 5000;
    await assert.rejects(callService(helper, directory, command), new RegExp(`HELPER_TIMEOUT.*${expected}ms`));
    assert.ok(Date.now() - began >= expected - 100, "must not timeout prematurely");
  }));
});

test("configDigest matches exact ConfigStore bytes with indentation and terminal newline", async t => {
  const { directory } = await fakeHelper(t, "process.exit(99);");
  const store = new ConfigStore(join(directory, "config"));
  const config = await store.update(() => emptyConfig());
  const bytes = await readFile(store.file);
  assert.equal(bytes.toString(), JSON.stringify(config, null, 2) + "\n");
  assert.equal(configDigest(config), createHash("sha256").update(bytes).digest("hex"));
  assert.match(configDigest(config), /^[a-f0-9]{64}$/);
  assert.notEqual(configDigest(config), createHash("sha256").update(JSON.stringify(config)).digest("hex"));
});
