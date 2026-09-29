import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { isAbsolute } from "node:path";
import type { Config } from "./config";
import { exact, MAX_BYTES, record } from "./config";

export type ServiceCommand = "start" | "status" | "reload" | "stop";
export interface ServiceState {
  running: boolean;
  executionEnabled: boolean;
  accessibilityTrusted: boolean;
  inputMonitoringTrusted: boolean;
  enabledBindings: number;
  configDigest: string | null;
  lastError: string | null;
  pid: number | null;
}

export class ServiceTransportError extends Error {
  constructor(readonly code: string, message: string) {
    super(`${code}: ${message}`);
    this.name = "ServiceTransportError";
  }
}

/** Hash the exact UTF-8 bytes written by ConfigStore, including its final newline. */
export function configDigest(config: Config): string {
  return createHash("sha256").update(JSON.stringify(config, null, 2) + "\n", "utf8").digest("hex");
}

/** A service reply is exactly one newline-terminated JSON line, without a protocolVersion. */
export function parseServiceResponse(stdout: string | Buffer, exitCode: number | null): ServiceState {
  let response: Record<string, unknown>;
  try {
    if (Buffer.byteLength(stdout) > MAX_BYTES) throw new Error("Response exceeds 1 MiB");
    const text = typeof stdout === "string" ? stdout : new TextDecoder("utf-8", { fatal: true }).decode(stdout);
    if (!text.endsWith("\n") || text.slice(0, -1).includes("\n") || text.includes("\r")) {
      throw new Error("Expected exactly one newline-terminated JSON line");
    }
    const value: unknown = JSON.parse(text);
    if (!record(value) || typeof value.ok !== "boolean") throw new Error("Invalid response envelope");
    exact(value, value.ok ? ["ok", "data"] : ["ok", "error"], "response");
    response = value;
    if (!value.ok) {
      exact(value.error, ["code", "message"], "error");
      if (exitCode !== 1 || typeof value.error.code !== "string" || typeof value.error.message !== "string") {
        throw new Error("Invalid error fields or exit status");
      }
    } else {
      if (exitCode !== 0) throw new Error("Success requires exit status 0");
      const state = value.data;
      exact(state, ["running", "executionEnabled", "accessibilityTrusted", "inputMonitoringTrusted", "enabledBindings", "configDigest", "lastError", "pid"], "service state");
      for (const key of ["running", "executionEnabled", "accessibilityTrusted", "inputMonitoringTrusted"]) {
        if (typeof state[key] !== "boolean") throw new Error(`Invalid ${key}`);
      }
      if (!Number.isSafeInteger(state.enabledBindings) || (state.enabledBindings as number) < 0) throw new Error("Invalid enabledBindings");
      if (state.configDigest !== null && (typeof state.configDigest !== "string" || !/^[a-f0-9]{64}$(?![\s\S])/.test(state.configDigest))) throw new Error("Invalid configDigest");
      if (state.lastError !== null && typeof state.lastError !== "string") throw new Error("Invalid lastError");
      if (state.running ? !Number.isSafeInteger(state.pid) || (state.pid as number) <= 0 : state.pid !== null || state.executionEnabled) {
        throw new Error("Contradictory running, executionEnabled or pid state");
      }
      if (state.executionEnabled && (!state.running || !state.accessibilityTrusted || !state.inputMonitoringTrusted || state.configDigest === null)) {
        throw new Error("Execution requires a running service, both permissions and a config digest");
      }
      return state as unknown as ServiceState;
    }
  } catch (error) {
    throw new ServiceTransportError("INVALID_RESPONSE", error instanceof Error ? error.message : String(error));
  }
  const error = response.error as { code: string; message: string };
  throw new ServiceTransportError(error.code, error.message);
}

/** Invoke only the requested operation. Never requests permissions or implicitly starts a service. */
export async function callService(helperPath: string, directory: string, command: ServiceCommand): Promise<ServiceState> {
  for (const [label, path] of [["helperPath", helperPath], ["directory", directory]]) {
    if (typeof path !== "string" || !isAbsolute(path) || path.includes("\0")) {
      throw new ServiceTransportError("INVALID_PATH", `${label} must be an absolute path without NUL bytes`);
    }
  }
  if (!["start", "status", "reload", "stop"].includes(command)) throw new ServiceTransportError("INVALID_COMMAND", "Unsupported service command");
  const timeoutMs = command === "start" ? 15000 : 5000;
  return new Promise((resolve, reject) => {
    const child = spawn(helperPath, [`service-${command}`, "--directory", directory], { shell: false, stdio: ["ignore", "pipe", "pipe"] });
    const chunks: Buffer[] = [];
    let done = false;
    let size = 0;
    const fail = (error: Error) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      child.kill("SIGKILL");
      reject(error);
    };
    const timer = setTimeout(() => fail(new ServiceTransportError("HELPER_TIMEOUT", `Service helper exceeded ${timeoutMs}ms`)), timeoutMs);
    child.on("error", error => fail(new ServiceTransportError("HELPER_UNAVAILABLE", error.message)));
    const consume = (chunk: Buffer, stdout: boolean) => {
      if (done) return;
      size += chunk.length;
      if (size > MAX_BYTES) fail(new ServiceTransportError("INVALID_RESPONSE", "Helper output exceeds 1 MiB"));
      else if (stdout) chunks.push(chunk);
    };
    child.stdout.on("data", (chunk: Buffer) => consume(chunk, true));
    child.stderr.on("data", (chunk: Buffer) => consume(chunk, false));
    child.on("close", code => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { resolve(parseServiceResponse(Buffer.concat(chunks), code)); }
      catch (error) { reject(error); }
    });
  });
}
