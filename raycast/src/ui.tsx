import { execFile } from "node:child_process";
import { Action, ActionPanel, Form, Icon, PopToRootType, Toast, closeMainWindow, environment, getPreferenceValues, showToast, useNavigation } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { getFrontmostApplication } from "@raycast/api";
import { resolveActiveApplication } from "./active-app";
import { resolveAppPath, appNameFromPath, ResolvedApp } from "./app-icon";
import { logDebug } from "./debug-log";
import { Anchor, Binding, Config, anchors, round2 } from "./config";
import { findShortcutConflict, formatShortcut } from "./shortcut";
import { ConfigStore } from "./storage";
import { ShortcutPicker } from "./shortcut-picker";
import { notifyConfigurationSaved } from "./service";
import { CaptureData, ShortcutData, callHelper } from "./transport";
export const store = new ConfigStore(environment.supportPath);
export const message = (e: unknown) => e instanceof Error ? e.message : String(e);
export async function failure(e: unknown) { await showToast({ style: Toast.Style.Failure, title: "AppBind refused operation", message: message(e) }); }

/** LaunchServices activation: `/usr/bin/open -a Raycast` needs no Automation/Accessibility grant. */
function execFileAsync(file: string, args: string[], options?: { timeout?: number }): Promise<void> {
  return new Promise((resolve, reject) => {
    execFile(file, args, options ?? {}, error => (error ? reject(error) : resolve()));
  });
}

/** 取点遮罩必须独占键盘，期间 Raycast 面板已关闭；结束后重新激活 Raycast，让表单回到前台继续编辑/保存。失败只记日志，不打断流程。 */
export async function reopenRaycast(): Promise<void> {
  try {
    await execFileAsync("/usr/bin/open", ["-a", "Raycast"], { timeout: 5000 });
  } catch (e) {
    await logDebug("pickPoint", `reopen Raycast failed: ${e instanceof Error ? e.message : String(e)}`);
  }
}
interface Values { id: string; name: string; enabled: boolean }
export function BindingForm({ binding, saved }: { binding?: Binding; saved?: (config: Config) => void }) {
  const { pop, push } = useNavigation(); const [busy, setBusy] = useState(false); const [error, setError] = useState<string>();
  const [bundleId, setBundleId] = useState(binding?.application.bundleId ?? "");
  const [appError, setAppError] = useState<string>();
  // 已识别应用的信息（名称/路径），用于展示该 appid 对应的 logo；按 id 单独反查，
  // 不使用 getApplications()（全量枚举会污染前台查询缓存）。
  const [appInfo, setAppInfo] = useState<ResolvedApp | undefined>();
  const [logoLoading, setLogoLoading] = useState(false);
  const appLookupSeq = useRef(0);
  const appLookupTimer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [detecting, setDetecting] = useState(false);
  const [anchor, setAnchor] = useState<Anchor>(binding?.action.anchor ?? "top-left");
  const [x, setX] = useState((binding?.action.offset.x ?? 0).toFixed(2));
  const [y, setY] = useState((binding?.action.offset.y ?? 0).toFixed(2));
  const [capturing, setCapturing] = useState(false);
  const [shortcut, setShortcut] = useState<ShortcutData | undefined>(binding ? { key: binding.trigger.key, modifiers: [...binding.trigger.modifiers] } : undefined);
  const [shortcutError, setShortcutError] = useState<string>();
  /** appid 字段形态：dropdown（内联显示解析到的应用 logo）或 manual（手动输入 Bundle ID）。 */
  const [appMode, setAppMode] = useState<"dropdown" | "manual">("dropdown");
  const interactiveSession = useRef(false);
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; if (appLookupTimer.current !== undefined) clearTimeout(appLookupTimer.current); }; }, []);
  /** 先拿到 appid，再查这个 id 对应的应用路径（logo）：mdfind → lsappinfo，都不命中则无图标。 */
  function refreshAppInfo(id: string) {
    const seq = ++appLookupSeq.current;
    setAppInfo(undefined);
    setLogoLoading(true);
    if (!id.trim()) { setLogoLoading(false); return; }
    void resolveAppPath(id).then(path => {
      if (!mounted.current || seq !== appLookupSeq.current) return;
      setLogoLoading(false);
      if (!path) { setAppInfo(undefined); return; }
      setAppInfo({ name: appNameFromPath(path, id), path });
    });
  }
  /** 手动输入 Bundle ID 时防抖反查 logo。 */
  function scheduleAppInfo(id: string) {
    if (appLookupTimer.current !== undefined) clearTimeout(appLookupTimer.current);
    if (!id.trim()) { setAppInfo(undefined); return; }
    appLookupTimer.current = setTimeout(() => { appLookupTimer.current = undefined; void refreshAppInfo(id); }, 350);
  }
  function recordShortcut() {
    if (busy || detecting || interactiveSession.current) return;
    push(<ShortcutPicker current={shortcut} onConfirm={async (candidate, isActive) => {
      const conflict = findShortcutConflict(await store.read(), bundleId, candidate, binding?.id);
      if (!mounted.current || !isActive()) throw new Error("设置已取消或表单已关闭，原值未改变。");
      if (conflict) throw new Error(`${formatShortcut(candidate)} 已用于此 App 的「${conflict.name}」。请选择其他组合，原值未改变。`);
      setShortcut(candidate);
      setShortcutError(undefined);
      await showToast({ style: Toast.Style.Success, title: "快捷键已确认，请保存规则", message: formatShortcut(candidate) });
    }} />);
  }
  const generation = useRef(0);
  async function detectApplication() {
    const request = ++generation.current;
    setDetecting(true);
    try {
      const app = await resolveActiveApplication(getFrontmostApplication);
      await logDebug("detectApp", `resolved ${app.bundleId} name="${app.name}"`);
      if (request !== generation.current) return;
      setBundleId(app.bundleId);
      setAppError(undefined);
      refreshAppInfo(app.bundleId);
    } catch (e) {
      await logDebug("detectApp", `failure: ${e instanceof Error ? e.message : String(e)}`);
      if (request === generation.current) setAppError(message(e));
    } finally { if (request === generation.current) setDetecting(false); }
  }
  useEffect(() => {
    if (binding) refreshAppInfo(binding.application.bundleId);
    else void detectApplication();
    return () => { generation.current++; };
  }, []);
  async function pickPoint() {
    await logDebug("pickPoint", `entered bundleId="${bundleId}" anchor="${anchor}" busy=${busy} detecting=${detecting} capturing=${capturing}`);
    if (busy || detecting || interactiveSession.current) return;
    // The helper never accepts client-provided identity beyond bundleId+anchor and never auto-fills anything; abort on an invalid form value instead of guessing.
    if (bundleId.length > 255 || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$(?![\s\S])/.test(bundleId)) {
      await logDebug("pickPoint", "aborted: invalid bundleId in form");
      await failure(new Error("请先在表单中填入或获取有效的 App Bundle ID，再开始取点。"));
      return;
    }
    interactiveSession.current = true;
    setCapturing(true);
    // 面板关闭期间产生的提示（确认/取消/失败）推迟到重新打开面板后再展示，否则用户看不到。
    let windowClosed = false;
    let pendingToast: { style: Toast.Style; title: string; message?: string } | undefined;
    try {
      // Precheck while the panel is still visible: a failing helper must produce a visible error.
      const helperPath = getPreferenceValues<{ helperPath: string }>().helperPath;
      await logDebug("pickPoint", `preflight status helperPath="${helperPath}"`);
      const preflight = await callHelper(helperPath, { protocolVersion: 1, command: "status" });
      await logDebug("pickPoint", `preflight ok=${preflight.ok} trusted=${preflight.ok ? preflight.data.accessibilityTrusted : "n/a"}`);
      if (!preflight.ok || !preflight.data.accessibilityTrusted) {
        await logDebug("pickPoint", "aborted: accessibility not trusted");
        pendingToast = { style: Toast.Style.Failure, title: "AppBind refused operation", message: "PERMISSION_DENIED: Helper 尚无辅助功能权限。请先在 系统设置 → 隐私与安全性 → 辅助功能 中授权 Helper，再重试。" };
        return;
      }
      // The picking overlay must become key, so close the Raycast panel first (closeMainWindow exists in @raycast/api 1.104.5 types).
      // PopToRootType.Suspended keeps the form alive as the view command: without it Raycast applies the
      // user's "Pop to Root Search" preference and the half-filled form would be popped when the panel reopens.
      await logDebug("pickPoint", "closing main window");
      await closeMainWindow({ clearRootSearch: true, popToRootType: PopToRootType.Suspended });
      windowClosed = true;
      await logDebug("pickPoint", `calling capture bundleId="${bundleId}" anchor="${anchor}"`);
      const response = await callHelper(helperPath, { protocolVersion: 1, command: "capture", bundleId, anchor });
      if (!response.ok) {
        await logDebug("pickPoint", `helper ended ${response.error.code}: ${response.error.message}`);
        if (response.error.code === "USER_CANCELLED") {
          pendingToast = { style: Toast.Style.Success, title: "取点已取消", message: "表单未修改，可直接重试或继续编辑。" };
        } else {
          pendingToast = { style: Toast.Style.Failure, title: "AppBind refused operation", message: `${response.error.code}: ${response.error.message}` };
        }
        return;
      }
      const d = response.data as unknown as CaptureData; // parseResponse validated the capture success shape for command === "capture"
      await logDebug("pickPoint", `confirmed offset=(${d.offset.x},${d.offset.y}) anchor=${d.anchor} pid=${d.pid}`);
      setAnchor(d.anchor); setX(d.offset.x.toFixed(2)); setY(d.offset.y.toFixed(2));
      pendingToast = { style: Toast.Style.Success, title: "偏移已填入，请保存规则" };
    } catch (e) {
      await logDebug("pickPoint", `exception: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}`);
      pendingToast = { style: Toast.Style.Failure, title: "AppBind refused operation", message: message(e) };
    } finally {
      // 取点结束后自动重新打开 Raycast 面板，回到表单继续编辑/保存；稍等面板出现再展示提示。
      if (windowClosed) {
        await logDebug("pickPoint", "reopening Raycast");
        await reopenRaycast();
        await new Promise(resolve => setTimeout(resolve, 350));
      }
      if (pendingToast) await showToast(pendingToast);
      interactiveSession.current = false;
      setCapturing(false);
    }
  }
  async function submit(v: Values) {
    if (busy || interactiveSession.current) return; setBusy(true); setError(undefined);
    try {
      if (!x.trim() || !y.trim() || !/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(x) || !/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(y)) throw new Error("Offsets must be decimal numbers");
      if (!shortcut) {
        setShortcutError("尚未设置快捷键，请点击底部「设置快捷键」。");
        throw new Error("请先设置快捷键");
      }
      const next: Binding = { id: binding?.id ?? v.id, name: v.name, enabled: v.enabled, application: { bundleId }, trigger: { type: "hotkey", key: shortcut.key, modifiers: shortcut.modifiers, scope: "frontmost-app" }, action: { type: "window-relative-click", window: "focused", anchor, offset: { x: round2(Number(x)), y: round2(Number(y)) }, button: "left", restoreCursor: true } };
      const config = await store.update(current => {
        if (binding) {
          const latest = current.bindings.find(b => b.id === binding.id);
          if (JSON.stringify(latest) !== JSON.stringify(binding)) throw new Error("Binding changed or was deleted; reopen before editing");
          return { ...current, bindings: current.bindings.map(b => b.id === binding.id ? next : b) };
        }
        return { ...current, bindings: [...current.bindings, next] };
      });
      const activationMessage = await notifyConfigurationSaved(config);
      if (saved) { saved(config); pop(); } else { setError(activationMessage); }
    } catch (e) { setError(message(e)); await failure(e); } finally { setBusy(false); }
  }
  return <Form isLoading={busy || detecting || capturing} navigationTitle={binding ? "Edit Binding" : "Create Binding"} actions={<ActionPanel>
      <ActionPanel.Section>
        <Action title="设置快捷键" icon={Icon.Keyboard} onAction={recordShortcut} />
        <Action title="从窗口取点" icon={Icon.TextCursor} onAction={pickPoint} />
        <Action title="重新检测前台 App" icon={Icon.RotateClockwise} onAction={() => { if (busy || interactiveSession.current) return; void detectApplication(); }} />
        {/* 手动输入模式下回到图标视图（仅当已有合法 Bundle ID 时）。 */}
        {appMode === "manual" && bundleId.trim() !== "" && <Action title="以图标视图查看应用" icon={Icon.AppWindow} onAction={() => setAppMode("dropdown")} />}
      </ActionPanel.Section>
      <ActionPanel.Section>
        <Action.SubmitForm title="保存" shortcut={{ modifiers: ["cmd"], key: "s" }} onSubmit={submit} />
      </ActionPanel.Section>
    </ActionPanel>}>
    {error && <Form.Description title="Result" text={error} />}
    {binding ? <Form.Description title="ID (immutable)" text={binding.id} /> : <Form.TextField id="id" title="ID" placeholder="toggle-sidebar" />}
    <Form.TextField id="name" title="Name" defaultValue={binding?.name} />
    {appMode === "manual"
      ? <Form.TextField id="bundleId" title="App Bundle ID" placeholder="自动从激活应用获取，也可手动修改" value={bundleId} error={appError} onChange={value => { generation.current++; setDetecting(false); setBundleId(value); setAppError(undefined); scheduleAppInfo(value); }} />
      : <Form.Dropdown id="app" title="应用" value={bundleId || "__empty__"} info="字段内显示当前 appid 解析出的应用与 logo；点击「重新检测前台 App」可重新获取前台应用。" onChange={value => {
        generation.current++; setDetecting(false); setAppError(undefined);
        if (value === "__manual__") { setAppMode("manual"); return; }
        if (value === "__empty__") return;
        setBundleId(value); scheduleAppInfo(value);
      }}>
        {/* 只有当前 bundleId 对应的项：受控值永远有匹配项，不可能回退成其他 App。 */}
        {!bundleId && <Form.Dropdown.Item value="__empty__" title="尚未获取 App ID：点击「重新检测前台 App」或手动输入" icon={Icon.QuestionMark} />}
        {bundleId && appInfo && <Form.Dropdown.Item value={bundleId} title={`${appInfo.name}（${bundleId}）`} icon={{ fileIcon: appInfo.path }} />}
        {bundleId && !appInfo && <Form.Dropdown.Item value={bundleId} title={logoLoading ? "正在查询该 App 的 logo…" : `${bundleId}（未找到图标）`} icon={Icon.QuestionMark} />}
        <Form.Dropdown.Item value="__manual__" title="手动输入 Bundle ID…" icon={Icon.Pencil} />
      </Form.Dropdown>}
    {bundleId.trim() !== "" && <Form.Description title="已识别应用" text={appInfo ? `${appInfo.name} · ${appInfo.path}` : (logoLoading ? "正在查询该 App 的 logo…" : "未找到该 App 的图标（未安装或不在本地索引中）；规则仍可保存")} />}
    {appError && appMode === "dropdown" && <Form.Description title="前台检测提示" text={appError} />}
    <Form.Description title="快捷键" text={shortcut ? formatShortcut(shortcut) : "尚未设置"} />
    {shortcutError && <Form.Description title="快捷键提示" text={shortcutError} />}
    <Form.Dropdown id="anchor" title="Anchor" value={anchor} onChange={value => setAnchor(value as Anchor)}>{anchors.map(a => <Form.Dropdown.Item key={a} value={a} title={a} />)}</Form.Dropdown>
    <Form.TextField id="x" title="Offset X" value={x} onChange={setX} />
    <Form.TextField id="y" title="Offset Y" value={y} onChange={setY} />
    <Form.Checkbox id="enabled" label="启用规则（后台服务运行时生效）" defaultValue={binding?.enabled ?? true} />
    <Form.Description text="保存会更新已运行的后台服务；未启动服务时仅保存，不自动开始监听。" />
  </Form>;
}
