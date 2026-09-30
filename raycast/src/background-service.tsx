import { Action, ActionPanel, Color, Detail, Icon, Toast, showToast } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { confirmServiceStart, serviceCommand } from "./service";
import { ServiceCommand, ServiceState } from "./service-transport";
import { restartService } from "./service-restart";

function StatusTags({ state }: { state: ServiceState }) {
  return (
    <>
      <Detail.Metadata.TagList title="运行状态">
        <Detail.Metadata.TagList.Item text={state.running ? "正在运行" : "已停止"} color={state.running ? Color.Green : Color.Red} />
        <Detail.Metadata.TagList.Item text={state.executionEnabled ? "监听与执行就绪" : "执行未就绪"} color={state.executionEnabled ? Color.Green : state.running ? Color.Orange : Color.Red} />
      </Detail.Metadata.TagList>
      <Detail.Metadata.Separator />
      <Detail.Metadata.TagList title="系统权限">
        <Detail.Metadata.TagList.Item text={state.accessibilityTrusted ? "辅助功能 · 已授权" : "辅助功能 · 未授权"} color={state.accessibilityTrusted ? Color.Green : Color.Red} />
        <Detail.Metadata.TagList.Item text={state.inputMonitoringTrusted ? "输入监控 · 已授权" : "输入监控 · 未授权"} color={state.inputMonitoringTrusted ? Color.Green : Color.Red} />
      </Detail.Metadata.TagList>
      <Detail.Metadata.Separator />
      <Detail.Metadata.Label title="已加载启用规则" icon={Icon.List} text={`${state.enabledBindings} 条`} />
      <Detail.Metadata.Label title="进程 PID" icon={Icon.Terminal} text={state.pid !== null ? String(state.pid) : "未运行"} />
      {state.configDigest !== null && <Detail.Metadata.Label title="配置指纹" icon={Icon.Fingerprint} text={`${state.configDigest.slice(0, 12)}…`} />}
      {state.lastError !== null && (
        <>
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label title="最近错误 / 暂停原因" icon={Icon.Warning} text={state.lastError} />
        </>
      )}
    </>
  );
}

function statusBanner(state: ServiceState | undefined, error: string | undefined): string {
  if (error) return "## ⚠️ 无法确认服务状态\n";
  if (!state) return "## ⏳ 正在查询服务状态…\n";
  if (state.executionEnabled) return "## ✅ 服务运行中,监听与执行就绪\n";
  if (state.running) return "## ⚠️ 服务已运行,但监听与执行未就绪\n";
  return "## ⛔ 服务未运行,快捷键不会执行\n";
}

function renderMarkdown(state: ServiceState | undefined, error: string | undefined, refreshedAt: Date | undefined): string {
  const sections = `## 运行方式\n\n- 启动后监听前台 App 和匹配的快捷键;未匹配的按键直接放行\n- 命中后等待按键释放,重新校验窗口与目标点,校验通过才真实点击\n- 目标窗口变更或安全条件不满足时自动取消\n\n## 配置生效\n\n- 保存、启停或删除规则会尝试通知已运行的服务重载,**不会自动启动服务**\n- 停止服务后快捷键不再执行;手动停止后服务不会自行重启\n\n## 权限与限制\n\n- 在「系统设置 → 隐私与安全性」中检查 Helper 的**辅助功能**与**输入监控**权限\n- 本命令不会自动弹出授权,也不会安装登录项\n- 系统保留快捷键、安全输入及部分应用窗口可能无法支持\n- 授权或重新编译后可能需要重启服务\n\n> 使用「刷新状态」查看最新信息。`;
  if (error) {
    return `# AppBind 后台服务\n\n${statusBanner(state, error)}\n${error}\n\n请使用「刷新状态」重试;若持续失败,可尝试「重启后台服务」,或在 Helper Status 中查看调试日志。\n\n${sections}`;
  }
  if (!state) {
    return `# AppBind 后台服务\n\n${statusBanner(state, error)}正在请求 Helper,首次查询或上次查询失败。\n\n${sections}`;
  }
  const lastError = state.lastError !== null && state.lastError ? `## 最近错误 / 暂停原因\n\n> ${state.lastError}\n\n` : "";
  const refreshed = refreshedAt ? `\n\n---\n\n_最近刷新:${refreshedAt.toLocaleTimeString()}_` : "";
  const detail = state.executionEnabled
    ? "正在监听前台 App 与已保存的快捷键,命中后校验通过才会真实点击。"
    : state.running
      ? "请检查下方权限状态与最近错误;授权后再执行「刷新状态」。"
      : "可执行「启动后台服务」开始监听;保存规则不会自动启动服务。";
  return `# AppBind 后台服务\n\n${statusBanner(state, error)}${detail}\n\n${lastError}${sections}${refreshed}`;
}

export default function BackgroundService() {
  const [state, setState] = useState<ServiceState>();
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);
  const [refreshedAt, setRefreshedAt] = useState<Date>();
  const lock = useRef(false);
  const alive = useRef(true);
  useEffect(() => { alive.current = true; void run("status"); return () => { alive.current = false; }; }, []);
  async function run(command: ServiceCommand | "restart") {
    if (lock.current) return;
    lock.current = true; setBusy(true);
    try {
      if ((command === "start" || command === "restart") && !await confirmServiceStart()) return;
      const result = command === "restart" ? await restartService(serviceCommand) : await serviceCommand(command);
      if (alive.current) { setState(result); setError(undefined); setRefreshedAt(new Date()); }
      if (command !== "status") await showToast({ style: result.lastError ? Toast.Style.Failure : Toast.Style.Success,
        title: command === "stop" ? "服务已停止" : command === "restart" ? "服务重启结果已更新" : command === "start" ? "启动结果已更新" : "重载结果已更新",
        message: result.lastError ?? (result.executionEnabled ? "监听与执行已就绪" : "执行未就绪,请检查状态") });
    } catch (e) {
      if (alive.current) { setError(e instanceof Error ? e.message : String(e)); setState(undefined); }
    } finally { lock.current = false; if (alive.current) setBusy(false); }
  }
  return <Detail navigationTitle="AppBind 后台服务" isLoading={busy} markdown={renderMarkdown(state, error, refreshedAt)} metadata={<Detail.Metadata>
    {state ? <StatusTags state={state} /> : <Detail.Metadata.Label title="状态" icon={Icon.Warning} text={error ? "无法确认" : "查询中"} />}
  </Detail.Metadata>} actions={<ActionPanel>
    <Action title="刷新状态" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["cmd"], key: "r" }} onAction={() => run("status")} />
    <Action title="重启后台服务" icon={Icon.ArrowClockwise} onAction={() => run("restart")} />
    <Action title="停止后台服务" icon={Icon.Stop} onAction={() => run("stop")} />
    <Action title="启动后台服务" icon={Icon.Play} onAction={() => run("start")} />
    <Action title="重载已保存的规则" icon={Icon.Download} onAction={() => run("reload")} />
  </ActionPanel>} />;
}