import { test } from "node:test";
import assert from "node:assert/strict";
import { defaultTimeoutMs, parseResponse, timeoutCapMs, validateRequest } from "../src/transport";

const captureRequest = { protocolVersion: 1, command: "capture", bundleId: "com.example.app", anchor: "top-left" };
const captureSuccess = { protocolVersion: 1, ok: true, data: { bundleId: "com.example.app", pid: 4242, frame: { x: -100, y: 50, width: 1200, height: 800 }, anchor: "center", offset: { x: 12.5, y: -3 }, target: { x: 512, y: 449 }, durationMs: 8123 } };

test("capture requests: exact shape, bundleId and anchor rules", () => {
  validateRequest({ ...captureRequest });
  validateRequest({ ...captureRequest, bundleId: "com." + "a".repeat(251), anchor: "bottom-right" }); // 255-char boundary still valid
  for (const missing of ["bundleId", "anchor"]) { const r: Record<string, unknown> = { ...captureRequest }; delete r[missing]; assert.throws(() => validateRequest(r)); }
  assert.throws(() => validateRequest({ ...captureRequest, config: {} }));
  assert.throws(() => validateRequest({ ...captureRequest, protocolVersion: 2 }));
  assert.throws(() => validateRequest({ ...captureRequest, anchor: "middle" }));
  assert.throws(() => validateRequest({ ...captureRequest, bundleId: "nodots" }));
  assert.throws(() => validateRequest({ ...captureRequest, bundleId: "" }));
  assert.throws(() => validateRequest({ ...captureRequest, bundleId: "com.example.app\n" })); // trailing newline rejected
  assert.throws(() => validateRequest({ ...captureRequest, bundleId: "com." + "a".repeat(252) })); // > 255 characters rejected
});

test("capture success payload is fully validated and malformed shapes rejected", () => {
  const parsed = parseResponse(Buffer.from(JSON.stringify(captureSuccess) + "\n"), "capture", 0);
  assert.equal(parsed.ok, true);
  assert.deepEqual(parsed.data, captureSuccess.data);
  assert.throws(() => parseResponse(Buffer.from(JSON.stringify(captureSuccess) + "\n"), "capture", 1)); // success with non-zero exit
  for (const change of [
    (d: any) => { delete d.offset; },
    (d: any) => { delete d.durationMs; },
    (d: any) => d.extra = true,
    (d: any) => d.offset.extra = true,
    (d: any) => d.offset.x = Infinity,
    (d: any) => d.offset.y = NaN,
    (d: any) => d.offset.x = 100001,
    (d: any) => d.offset.y = -100001,
    (d: any) => d.target.x = Number.POSITIVE_INFINITY,
    (d: any) => d.target.y = 100001,
    (d: any) => d.pid = 0,
    (d: any) => d.pid = -1,
    (d: any) => d.pid = 1.5,
    (d: any) => d.pid = Number.MAX_SAFE_INTEGER + 2,
    (d: any) => d.bundleId = "nodots",
    (d: any) => d.bundleId += "\n",
    (d: any) => d.anchor = "middle",
    (d: any) => d.frame.x = Infinity,
    (d: any) => d.frame.width = 0,
    (d: any) => d.frame.height = -1,
    (d: any) => d.frame.extra = true,
    (d: any) => d.durationMs = NaN,
    (d: any) => d.durationMs = -1,
  ]) { const r = structuredClone(captureSuccess); change(r.data); assert.throws(() => parseResponse(Buffer.from(JSON.stringify(r) + "\n"), "capture", 0)); }
});

test("capture error responses accept APP_NOT_RUNNING and USER_CANCELLED, reject unknown codes", () => {
  for (const code of ["APP_NOT_RUNNING", "USER_CANCELLED"]) {
    const r = { protocolVersion: 1, ok: false, error: { code, message: "capture did not complete" } };
    const parsed = parseResponse(Buffer.from(JSON.stringify(r) + "\n"), "capture", 1);
    assert.equal(parsed.ok, false);
    assert.equal(parsed.error.code, code);
  }
  assert.throws(() => parseResponse(Buffer.from(JSON.stringify({ protocolVersion: 1, ok: false, error: { code: "OLD_ONE", message: "x" } }) + "\n"), "capture", 1), /Invalid error/);
  assert.throws(() => parseResponse(Buffer.from(JSON.stringify({ protocolVersion: 1, ok: false, error: { code: "USER_CANCELLED", message: "x" } }) + "\n"), "capture", 0), /Invalid error/);
});

test("timeout policy: capture gets long default/cap, other commands keep 3000/10000", () => {
  assert.equal(defaultTimeoutMs("capture"), 150000);
  assert.equal(timeoutCapMs("capture"), 150000);
  for (const command of ["status", "inspect", "dry-run"] as const) {
    assert.equal(defaultTimeoutMs(command), 3000);
    assert.equal(timeoutCapMs(command), 10000);
  }
});