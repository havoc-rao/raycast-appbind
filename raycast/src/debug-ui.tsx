import { Action, ActionPanel, Detail, getPreferenceValues } from "@raycast/api";
import { useEffect, useState } from "react";
import { logFile, readLogTail } from "./debug-log";
import { Request, callHelper } from "./transport";
const message = (e: unknown) => e instanceof Error ? e.message : String(e);
export const warning = "Diagnostic only — no click, cursor movement, app activation, or hotkey registration. Raycast may be the frontmost app; APP_MISMATCH is expected in that case. We never hide Raycast and guess a previous window. A successful dry-run does not attest click safety.";
export function DebugLog() {
  const [text, setText] = useState("读取中…"); const [file, setFile] = useState("…"); const [loading, setLoading] = useState(true);
  async function reload() { setLoading(true); try { setFile(await logFile()); setText(await readLogTail()); } catch (e) { setText(message(e)); } finally { setLoading(false); } }
  useEffect(() => { void reload(); }, []);
  return <Detail isLoading={loading} markdown={`# AppBind 调试日志\n\n文件位置：\`${file}\`\n\n\`\`\`text\n${text}\n\`\`\``} actions={<ActionPanel><Action title="刷新日志" onAction={reload} /><Action.CopyToClipboard title="复制日志路径" content={file} /></ActionPanel>} />;
}
export function Diagnostic({ request }: { request: Request }) {
  const [text, setText] = useState("Querying helper…"); const [loading, setLoading] = useState(true);
  async function run() {
    setLoading(true);
    try {
      const response = await callHelper(getPreferenceValues<{ helperPath: string }>().helperPath, request);
      setText("```json\n" + JSON.stringify(response, null, 2) + "\n```");
    } catch (e) { setText(message(e)); } finally { setLoading(false); }
  }
  useEffect(() => { void run(); }, []);
  return <Detail isLoading={loading} markdown={`# ${request.command}\n\n${warning}\n\n${text}`} actions={<ActionPanel><Action title="Refresh Diagnostic" onAction={run} /></ActionPanel>} />;
}
