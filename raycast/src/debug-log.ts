// Debug log channel. Never throws: diagnostics must never break the UI flow.
// The log lives in the extension's own support directory (environment.supportPath).
// The @raycast/api environment is imported lazily so unit tests can exercise the
// file helpers without a Raycast runtime.
import * as fs from "node:fs/promises";
import path from "node:path";

const MAX_BYTES = 256 * 1024;

export async function logFile(): Promise<string> {
  const { environment } = await import("@raycast/api");
  return path.join(environment.supportPath, "appbind.log");
}

export async function appendLog(file: string, area: string, message: string): Promise<void> {
  try {
    const line = `${new Date().toISOString()} [${area}] ${message}\n`;
    await fs.mkdir(path.dirname(file), { recursive: true });
    const stat = await fs.stat(file).catch(() => null);
    if (stat && stat.size > MAX_BYTES) {
      const tail = (await fs.readFile(file, "utf8")).slice(-MAX_BYTES / 2);
      await fs.writeFile(file, !tail.endsWith("\n") ? tail + "\n" : tail, "utf8");
    }
    await fs.appendFile(file, line, "utf8");
  } catch {
    // Never propagate logging failures.
  }
}

export function logDebug(area: string, message: string): Promise<void> {
  return logFile().then(file => appendLog(file, area, message));
}

export async function readLogTail(budget = 32 * 1024, explicitFile?: string): Promise<string> {
  try {
    const file = explicitFile ?? (await logFile());
    const text = await fs.readFile(file, "utf8");
    return text.length > budget ? `…（已截断至末尾 ${budget} 字节）\n` + text.slice(-budget) : text;
  } catch {
    return "（暂无日志：还没有触发过任何被记录的操作）";
  }
}