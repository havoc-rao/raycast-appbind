import { spawn } from "node:child_process";
import { isAbsolute } from "node:path";
import { Anchor, Config, Modifier, MAX_BYTES, anchors, modifiers, exact, record, validateConfig } from "./config";
export type Request = { protocolVersion: 1; command: "status" | "inspect" | "record-shortcut" } | { protocolVersion: 1; command: "dry-run"; config: Config; bindingId: string } | { protocolVersion: 1; command: "capture"; bundleId: string; anchor: Anchor };
export type Response = { protocolVersion: 1; ok: true; data: Record<string, unknown> } | { protocolVersion: 1; ok: false; error: { code: string; message: string } };
export interface ShortcutData { key: string; modifiers: Modifier[] }
export interface CaptureData { bundleId: string; pid: number; frame: { x: number; y: number; width: number; height: number }; anchor: Anchor; offset: { x: number; y: number }; target: { x: number; y: number }; durationMs: number }
const codes = new Set(["INVALID_REQUEST", "UNSUPPORTED_VERSION", "INVALID_CONFIG", "BINDING_NOT_FOUND", "BINDING_DISABLED", "PERMISSION_DENIED", "NO_FRONTMOST_APP", "APP_MISMATCH", "APP_NOT_RUNNING", "UNSAFE_TARGET", "USER_CANCELLED", "SAFETY_NOT_IMPLEMENTED", "INTERNAL_ERROR"]);
export class TransportError extends Error { constructor(readonly code: "HELPER_UNAVAILABLE" | "HELPER_TIMEOUT" | "INVALID_RESPONSE", message: string) { super(`${code}: ${message}`); } }
export function validateRequest(value: unknown): asserts value is Request {
  if (!record(value)) throw new Error("Invalid request");
  if (value.command === "status" || value.command === "inspect" || value.command === "record-shortcut") exact(value, ["protocolVersion", "command"], "request");
  else if (value.command === "dry-run") {
    exact(value, ["protocolVersion", "command", "config", "bindingId"], "request"); validateConfig(value.config);
    if (typeof value.bindingId !== "string" || !/^[a-z0-9][a-z0-9-]{0,63}$(?![\s\S])/.test(value.bindingId)) throw new Error("Invalid bindingId");
  } else if (value.command === "capture") {
    exact(value, ["protocolVersion", "command", "bundleId", "anchor"], "request");
    if (typeof value.bundleId !== "string" || value.bundleId.length > 255 || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$(?![\s\S])/.test(value.bundleId)) throw new Error("Invalid bundleId");
    if (!anchors.includes(value.anchor as Anchor)) throw new Error("Invalid anchor");
  } else throw new Error("Unsupported command: execution is disabled");
  if (value.protocolVersion !== 1) throw new Error("Unsupported protocolVersion");
}
/** Interactive capture/recording sessions allow 120s plus margin; diagnostics retain short timeouts. */
export function defaultTimeoutMs(command: Request["command"]): number { return (command === "capture" || command === "record-shortcut") ? 150000 : 3000; }
export function timeoutCapMs(command: Request["command"]): number { return (command === "capture" || command === "record-shortcut") ? 150000 : 10000; }
function geometry(v: unknown): boolean { return typeof v === "number" && Number.isFinite(v) && Math.abs(v) <= 100000; }
export function parseResponse(bytes: Buffer, command: Request["command"], exitCode: number | null): Response {
  try {
    if (bytes.length > MAX_BYTES) throw new Error("Oversized response");
    const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    if (!text.endsWith("\n")) throw new Error("Missing response newline");
    const r: unknown = JSON.parse(text);
    if (!record(r) || r.protocolVersion !== 1 || typeof r.ok !== "boolean") throw new Error("Invalid envelope/version");
    exact(r, r.ok ? ["protocolVersion", "ok", "data"] : ["protocolVersion", "ok", "error"], "response");
    if (r.ok) {
      if (exitCode !== 0 || !record(r.data)) throw new Error("Invalid success/exit");
      const d = r.data;
      if (command === "status") {
        exact(d, ["helperVersion", "accessibilityTrusted", "executionEnabled"], "status");
        if (typeof d.helperVersion !== "string" || !d.helperVersion || typeof d.accessibilityTrusted !== "boolean" || d.executionEnabled !== false) throw new Error("Invalid status");
      } else if (command === "record-shortcut") {
        exact(d, ["key", "modifiers"], "shortcut");
        if (typeof d.key !== "string" || !/^[a-z0-9]$(?![\s\S])/.test(d.key)) throw new Error("Invalid shortcut key");
        if (!Array.isArray(d.modifiers) || d.modifiers.length === 0 || d.modifiers.some(m => !modifiers.includes(m as Modifier)) || new Set(d.modifiers).size !== d.modifiers.length) throw new Error("Invalid shortcut modifiers");
      } else if (command === "capture") {
        exact(d, ["bundleId", "pid", "frame", "anchor", "offset", "target", "durationMs"], "capture");
        if (typeof d.bundleId !== "string" || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$(?![\s\S])/.test(d.bundleId) || !Number.isSafeInteger(d.pid) || (d.pid as number) <= 0) throw new Error("Invalid capture identity");
        exact(d.frame, ["x", "y", "width", "height"], "frame");
        if (!Object.values(d.frame).every(geometry) || (d.frame.width as number) <= 0 || (d.frame.height as number) <= 0) throw new Error("Invalid frame");
        if (!anchors.includes(d.anchor as Anchor)) throw new Error("Invalid anchor");
        exact(d.offset, ["x", "y"], "offset"); exact(d.target, ["x", "y"], "target");
        for (const n of [d.offset.x, d.offset.y, d.target.x, d.target.y]) if (typeof n !== "number" || !Number.isFinite(n) || Math.abs(n) > 100000) throw new Error("Invalid capture point");
        if (typeof d.durationMs !== "number" || !Number.isFinite(d.durationMs) || (d.durationMs as number) < 0) throw new Error("Invalid durationMs");
      } else {
        exact(d, command === "inspect" ? ["bundleId", "pid", "frame", "diagnosticOnly"] : ["bindingId", "bundleId", "pid", "frame", "target", "diagnosticOnly"], "diagnostic");
        if (typeof d.bundleId !== "string" || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$(?![\s\S])/.test(d.bundleId) || !Number.isSafeInteger(d.pid) || (d.pid as number) <= 0 || d.diagnosticOnly !== true) throw new Error("Invalid diagnostic identity");
        exact(d.frame, ["x", "y", "width", "height"], "frame");
        if (!Object.values(d.frame).every(geometry) || (d.frame.width as number) <= 0 || (d.frame.height as number) <= 0) throw new Error("Invalid frame");
        if (command === "dry-run") {
          if (typeof d.bindingId !== "string" || !/^[a-z0-9][a-z0-9-]{0,63}$(?![\s\S])/.test(d.bindingId)) throw new Error("Invalid bindingId");
          exact(d.target, ["x", "y"], "target");
          const x = d.target.x, y = d.target.y;
          if (typeof x !== "number" || typeof y !== "number" || !Number.isFinite(x) || !Number.isFinite(y) || x < (d.frame.x as number) || y < (d.frame.y as number) || x >= (d.frame.x as number) + (d.frame.width as number) || y >= (d.frame.y as number) + (d.frame.height as number)) throw new Error("Invalid target or outside half-open window bounds");
        }
      }
    } else {
      exact(r.error, ["code", "message"], "error");
      if (exitCode !== 1 || typeof r.error.code !== "string" || !codes.has(r.error.code) || typeof r.error.message !== "string" || !r.error.message) throw new Error("Invalid error/exit");
    }
    return r as Response;
  } catch (e) { throw new TransportError("INVALID_RESPONSE", e instanceof Error ? e.message : String(e)); }
}
export async function callHelper(helperPath: string, request: Request, options: { timeoutMs?: number; maxOutputBytes?: number } = {}): Promise<Response> {
  if (!isAbsolute(helperPath) || helperPath.includes("\0")) throw new TransportError("HELPER_UNAVAILABLE", "Set an explicit absolute helper executable path in extension preferences");
  validateRequest(request);
  const input = JSON.stringify(request);
  if (Buffer.byteLength(input) > MAX_BYTES) throw new Error("Request exceeds 1 MiB");
  const timeout = Math.min(timeoutCapMs(request.command), Math.max(10, options.timeoutMs ?? defaultTimeoutMs(request.command)));
  const cap = Math.min(MAX_BYTES, Math.max(1, options.maxOutputBytes ?? MAX_BYTES));
  return new Promise((resolve, reject) => {
    const child = spawn(helperPath, [], { shell: false, stdio: ["pipe", "pipe", "pipe"] });
    let done = false, size = 0; const chunks: Buffer[] = [];
    const fail = (error: Error) => { if (done) return; done = true; clearTimeout(timer); child.kill("SIGKILL"); reject(error); };
    const timer = setTimeout(() => fail(new TransportError("HELPER_TIMEOUT", `Helper exceeded ${timeout}ms`)), timeout);
    child.on("error", e => fail(new TransportError("HELPER_UNAVAILABLE", e.message)));
    child.stdin.on("error", () => { /* EPIPE is adjudicated by close/response validation. */ });
    const consume = (chunk: Buffer, stdout: boolean) => { size += chunk.length; if (size > cap) fail(new TransportError("INVALID_RESPONSE", "Helper output exceeded limit")); else if (!done && stdout) chunks.push(chunk); };
    child.stdout.on("data", (chunk: Buffer) => consume(chunk, true));
    child.stderr.on("data", (chunk: Buffer) => consume(chunk, false));
    child.on("close", (code) => {
      if (done) return; done = true; clearTimeout(timer);
      try {
        const response = parseResponse(Buffer.concat(chunks), request.command, code);
        if (response.ok && request.command === "dry-run" && (response.data.bindingId !== request.bindingId || response.data.bundleId !== request.config.bindings.find(b => b.id === request.bindingId)?.application.bundleId)) throw new TransportError("INVALID_RESPONSE", "Response identity mismatch");
        resolve(response);
      } catch (e) { reject(e); }
    });
    child.stdin.end(input);
  });
}
