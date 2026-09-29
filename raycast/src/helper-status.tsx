import { Action, ActionPanel, Detail } from "@raycast/api";
import { useEffect, useState } from "react";
import { message, store } from "./ui";
import { DebugLog, Diagnostic, warning } from "./debug-ui";
import { logFile, readLogTail } from "./debug-log";
import BackgroundService from "./background-service";
export default function HelperStatus() {
  const [state, setState] = useState("Checking configuration…");
  const [tail, setTail] = useState("读取日志…");
  const [file, setFile] = useState("…");
  useEffect(() => {
    store.read().then(c => setState(`${c.bindings.length} validated binding definitions`)).catch(e => setState(`Config error (not reset): ${message(e)}`));
    logFile().then(setFile).catch(() => setFile("(log path unavailable)"));
    readLogTail(4000).then(setTail).catch(e => setTail(message(e)));
  }, []);
  return <Detail markdown={`# AppBind — 诊断与后台服务\n\n${warning}\n\n## Configuration\n${state}\n\n## Helper\nUse Check Helper Status to query version and existing Accessibility trust without prompting. Inspect Frontmost queries the live frontmost app, never a guessed prior app.\n\nThe helper path must be explicitly configured in extension preferences. No service installation, permission grants, or focus restoration is performed.\n\nStale config.lock: only remove manually after verifying that no writer is running.\n\n## 最近调试日志\n文件：\`${file}\`\n\n\`\`\`text\n${tail}\n\`\`\``} actions={<ActionPanel>
    <Action.Push title="后台服务：启动 / 停止 / 状态" target={<BackgroundService />} />
    <Action.Push title="Check Helper Status" target={<Diagnostic request={{ protocolVersion: 1, command: "status" }} />} />
    <Action.Push title="Inspect Frontmost (No Click)" target={<Diagnostic request={{ protocolVersion: 1, command: "inspect" }} />} />
    <Action.Push title="查看完整调试日志" target={<DebugLog />} />
  </ActionPanel>} />;
}