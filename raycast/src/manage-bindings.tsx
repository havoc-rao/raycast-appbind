import { Action, ActionPanel, Alert, Icon, List, confirmAlert } from "@raycast/api";
import { useEffect, useState } from "react";
import { Binding, Config } from "./config";
import { BindingForm, failure, message, store } from "./ui";
import { BindingDebugActions } from "./debug-actions";
import BackgroundService from "./background-service";
import { notifyConfigurationSaved } from "./service";
import { resolveAppPath } from "./app-icon";
export default function ManageBindings() {
  const [config, setConfig] = useState<Config>(); const [error, setError] = useState<string>(); const [loading, setLoading] = useState(true);
  // 按绑定中的 bundle id 逐一反查应用路径（logo），不使用 getApplications()（避免污染前台查询缓存）。
  const [appPaths, setAppPaths] = useState<Record<string, string>>({});
  useEffect(() => {
    let alive = true;
    setAppPaths({});
    for (const b of config?.bindings ?? []) {
      const id = b.application.bundleId;
      void resolveAppPath(id).then(path => { if (alive && path) setAppPaths(m => (m[id] === path ? m : { ...m, [id]: path })); });
    }
    return () => { alive = false; };
  }, [config?.bindings]);
  async function load() { setLoading(true); try { setConfig(await store.read()); setError(undefined); } catch (e) { setConfig(undefined); setError(message(e)); } finally { setLoading(false); } }
  useEffect(() => { void load(); }, []);
  async function change(binding: Binding, remove: boolean) {
    if (remove && !await confirmAlert({ title: `Delete ${binding.name}?`, message: "Permanently removes this binding definition.", primaryAction: { title: "Delete", style: Alert.ActionStyle.Destructive } })) return;
    try {
      const next = await store.update(current => {
        if (JSON.stringify(current.bindings.find(b => b.id === binding.id)) !== JSON.stringify(binding)) throw new Error("Binding changed; refresh before modifying");
        return { ...current, bindings: remove ? current.bindings.filter(b => b.id !== binding.id) : current.bindings.map(b => b.id === binding.id ? { ...b, enabled: !b.enabled } : b) };
      });
      setConfig(next);
      await notifyConfigurationSaved(next);
    } catch (e) { await failure(e); }
  }
  const common = <><Action.Push title="Create Binding" icon={Icon.Plus} target={<BindingForm saved={setConfig} />} /><Action title="Reload Configuration" icon={Icon.ArrowClockwise} onAction={load} /><Action.Push title="后台服务" target={<BackgroundService />} /></>;
  return <List isLoading={loading} searchBarPlaceholder="搜索规则或应用" actions={<ActionPanel>{common}</ActionPanel>}>
    {error ? <List.EmptyView title="Configuration unavailable — not reset" description={error} /> : !config?.bindings.length ? <List.EmptyView title="No binding definitions" description="创建规则后，在后台服务页面显式启动监听。" /> : <List.Section title="已保存规则" subtitle="启用标记不等于服务正在运行；请查看后台服务">
      {config.bindings.map(b => <List.Item key={b.id} title={b.name} subtitle={b.application.bundleId} keywords={[b.id, b.trigger.key]} icon={appPaths[b.application.bundleId] ? { fileIcon: appPaths[b.application.bundleId] } : (b.enabled ? Icon.CheckCircle : Icon.Circle)} accessories={[{ text: [...b.trigger.modifiers, b.trigger.key].join("+") }, { text: b.enabled ? "Enabled" : "Disabled" }]} actions={<ActionPanel>
        <Action.Push title="Edit Binding" target={<BindingForm binding={b} saved={setConfig} />} />
        <Action title={b.enabled ? "Disable Binding" : "Enable Binding"} onAction={() => change(b, false)} />
        <BindingDebugActions config={config} bindingId={b.id} />
        <Action title="Delete Binding" style={Action.Style.Destructive} onAction={() => change(b, true)} />{common}
      </ActionPanel>} />)}
    </List.Section>}
  </List>;
}
