import { Action, ActionPanel, Detail, Icon, Toast, showToast } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { confirmServiceStart, serviceCommand } from "./service";
import { ServiceCommand, ServiceState } from "./service-transport";
import { restartService } from "./service-restart";

export default function BackgroundService() {
  const [state, setState] = useState<ServiceState>();
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);
  const lock = useRef(false);
  const alive = useRef(true);
  useEffect(() => { alive.current = true; void run("status"); return () => { alive.current = false; }; }, []);
  async function run(command: ServiceCommand | "restart") {
    if (lock.current) return;
    lock.current = true; setBusy(true);
    try {
      if ((command === "start" || command === "restart") && !await confirmServiceStart()) return;
      const result = command === "restart" ? await restartService(serviceCommand) : await serviceCommand(command);
      if (alive.current) { setState(result); setError(undefined); }
      if (command !== "status") await showToast({ style: result.lastError ? Toast.Style.Failure : Toast.Style.Success,
        title: command === "stop" ? "服务已停止" : command === "restart" ? "服务重启结果已更新" : command === "start" ? "启动结果已更新" : "重载结果已更新",
        message: result.lastError ?? (result.executionEnabled ? "监听与执行已就绪" : "执行未就绪，请检查状态") });
    } catch (e) {
      if (alive.current) { setError(e instanceof Error ? e.message : String(e)); setState(undefined); }
    } finally { lock.current = false; if (alive.current) setBusy(false); }
  }
  const yes = (value: boolean) => value ? "是" : "否";
  const markdown = `# AppBind 后台服务\n\n${error ? `## 无法确认状态\n${error}\n\n` : ""}${state ? `| 项目 | 状态 |\n|---|---|\n| 正在运行 | ${yes(state.running)} |\n| 监听与执行就绪 | ${yes(state.executionEnabled)} |\n| 辅助功能权限 | ${yes(state.accessibilityTrusted)} |\n| 输入监控权限 | ${yes(state.inputMonitoringTrusted)} |\n| 已加载启用规则 | ${state.enabledBindings} |\n| 进程 | ${state.pid ?? "—"} |\n\n${state.lastError ? `## 最近错误 / 暂停原因\n${state.lastError}\n\n` : ""}` : "正在查询或状态未知。\n\n"}## 运行方式\n\n启动后监听前台 App 和匹配快捷键；未匹配的按键放行。匹配后等待按键释放，重新校验窗口和目标点，校验通过才真实点击。目标变更或安全条件不满足时取消。\n\n保存、启停或删除规则会尝试通知已运行的服务重载，**不会自动启动服务**。停止服务后快捷键不再执行。\n\n## 权限与限制\n\n请在系统设置 → 隐私与安全性中检查 Helper 的辅助功能、输入监控权限；本命令不自动弹授权或安装登录项。系统保留快捷键、安全输入和部分应用窗口可能无法支持。授权或重新编译后可能需要重新启动服务。\n\n使用「刷新状态」查看最新信息。手动停止后服务不会自行重启。`;
  return <Detail isLoading={busy} markdown={markdown} actions={<ActionPanel>
    <Action title="刷新状态" icon={Icon.ArrowClockwise} onAction={() => run("status")} />
    <Action title="重启后台服务" icon={Icon.ArrowClockwise} onAction={() => run("restart")} />
    <Action title="停止后台服务" icon={Icon.Stop} onAction={() => run("stop")} />
    <Action title="启动后台服务" icon={Icon.Play} onAction={() => run("start")} />
    <Action title="重载已保存的规则" onAction={() => run("reload")} />
  </ActionPanel>} />;
}
