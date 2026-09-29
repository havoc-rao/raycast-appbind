import { Alert, Toast, confirmAlert, environment, getPreferenceValues, showToast } from "@raycast/api";
import { Config } from "./config";
import { ServiceCommand, callService, configDigest } from "./service-transport";

export function serviceCommand(command: ServiceCommand) {
  return callService(getPreferenceValues<{ helperPath: string }>().helperPath, environment.supportPath, command);
}

/** Reload only a running service. Saving never starts an input listener. */
export async function notifyConfigurationSaved(config: Config): Promise<string> {
  try {
    const before = await serviceCommand("status");
    if (!before.running) {
      const text = "已保存；后台服务未运行，请在后台服务页面显式启动。";
      await showToast({ style: Toast.Style.Success, title: "已保存，尚未生效", message: text });
      return text;
    }
    const state = await serviceCommand("reload");
    if (!state.running || !state.executionEnabled || state.configDigest !== configDigest(config)) {
      throw new Error(state.lastError ?? "服务未就绪或加载的配置版本不一致，请检查后台服务。");
    }
    const text = `已保存并加载到后台服务（${state.enabledBindings} 条启用规则）。实际触发仍需通过窗口安全校验。`;
    await showToast({ style: Toast.Style.Success, title: "已保存并生效", message: text });
    return text;
  } catch (error) {
    const text = `配置已保存，但无法确认生效：${error instanceof Error ? error.message : String(error)}`;
    await showToast({ style: Toast.Style.Failure, title: "已保存，服务同步失败", message: text });
    return text;
  }
}

export async function confirmServiceStart(): Promise<boolean> {
  return confirmAlert({
    title: "启动后台快捷键与点击服务？",
    message: "启用规则会监听当前 App 的快捷键，并在安全校验通过后真实点击窗口。需要辅助功能和输入监控权限。服务持续运行至手动停止；不会安装登录项。",
    primaryAction: { title: "启动服务", style: Alert.ActionStyle.Default },
  });
}
