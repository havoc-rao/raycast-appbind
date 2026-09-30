import { Action, ActionPanel, Form, Icon, Toast, closeMainWindow, environment, getPreferenceValues, showToast, useNavigation } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { getFrontmostApplication } from "@raycast/api";
import { AppInfo, installedApps } from "./apps";
import { resolveActiveApplication, ActiveApplication } from "./active-app";
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
/** Keep the auto-detect loading state visible long enough to be perceivable. */
const DETECT_MIN_MS = 750;
interface Values { id: string; name: string; enabled: boolean }
export function BindingForm({ binding, saved }: { binding?: Binding; saved?: (config: Config) => void }) {
  const { pop, push } = useNavigation(); const [busy, setBusy] = useState(false); const [error, setError] = useState<string>();
  const [bundleId, setBundleId] = useState(binding?.application.bundleId ?? "");
  const [appError, setAppError] = useState<string>();
  const [appInfo, setAppInfo] = useState<AppInfo>();
  const [installed, setInstalled] = useState<AppInfo[]>([]);
  const [appMode, setAppMode] = useState<"dropdown" | "manual">("dropdown");
  const appLookup = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [detecting, setDetecting] = useState(false);
  const [anchor, setAnchor] = useState<Anchor>(binding?.action.anchor ?? "top-left");
  const [x, setX] = useState((binding?.action.offset.x ?? 0).toFixed(2));
  const [y, setY] = useState((binding?.action.offset.y ?? 0).toFixed(2));
  const [capturing, setCapturing] = useState(false);
  const [shortcut, setShortcut] = useState<ShortcutData | undefined>(binding ? { key: binding.trigger.key, modifiers: [...binding.trigger.modifiers] } : undefined);
  const [shortcutError, setShortcutError] = useState<string>();
  const interactiveSession = useRef(false);
  const mounted = useRef(true);
  // One shared enumeration of installed apps, awaited by both the Logo dropdown and auto-detection.
  const installedPromise = useRef<Promise<AppInfo[]> | undefined>(undefined);
  if (!installedPromise.current) installedPromise.current = installedApps().then(list => list, () => []);
  useEffect(() => {
    mounted.current = true;
    void installedPromise.current!.then(setInstalled);
    return () => { mounted.current = false; if (appLookup.current !== undefined) clearTimeout(appLookup.current); };
  }, []);
  // Animated ellipsis while auto-detection is in progress.
  const [dots, setDots] = useState(1);
  useEffect(() => {
    if (!detecting) { setDots(1); return; }
    const timer = setInterval(() => setDots(d => (d % 3) + 1), 300);
    return () => clearInterval(timer);
  }, [detecting]);
  /** Debounced lookup of the installed app matching a bundle id, for the "已识别应用" hint. */
  function scheduleAppLookup(id: string) {
    if (appLookup.current !== undefined) clearTimeout(appLookup.current);
    if (!id.trim()) { setAppInfo(undefined); return; }
    appLookup.current = setTimeout(() => {
      appLookup.current = undefined;
      void installedApps()
        .then(list => {
          const needle = id.trim();
          const match = list.find(app => app.bundleId === needle)
            ?? list.find(app => app.bundleId.toLowerCase() === needle.toLowerCase());
          if (match !== undefined) setAppInfo({ name: match.name, path: match.path, bundleId: match.bundleId });
          else setAppInfo(undefined);
        })
        .catch(() => setAppInfo(undefined));
    }, 350);
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
    const startedAt = Date.now();
    setDetecting(true);
    let resolved: ActiveApplication | undefined;
    let detectError: string | undefined;
    try {
      resolved = await resolveActiveApplication(getFrontmostApplication);
      await logDebug("detectApp", `resolved ${resolved.bundleId} name="${resolved.name}"`);
    } catch (e) {
      await logDebug("detectApp", `failure: ${e instanceof Error ? e.message : String(e)}`);
      detectError = message(e);
    }
    // Keep the loading animation visible for at least DETECT_MIN_MS before anything appears.
    const remain = DETECT_MIN_MS - (Date.now() - startedAt);
    if (remain > 0) await new Promise(resolve => setTimeout(resolve, remain));
    if (request !== generation.current) return;
    setDetecting(false);
    if (detectError !== undefined || resolved === undefined) { setAppMode("manual"); setAppError(detectError ?? "未能获取前台应用"); return; }
    // Land bundle id and logo atomically: wait for the installed-app list so the dropdown never flashes a wrong value.
    const list = await installedPromise.current!;
    if (request !== generation.current) return;
    const match = list.find(app => app.bundleId === resolved!.bundleId) ?? list.find(app => app.bundleId.toLowerCase() === resolved!.bundleId.toLowerCase());
    setBundleId(resolved!.bundleId);
    setAppInfo(match ? { name: match.name, path: match.path, bundleId: match.bundleId } : undefined);
    setAppMode("dropdown");
    setAppError(undefined);
  }
  const editResolved = useRef(false);
  useEffect(() => {
    if (binding && installed.length > 0 && !editResolved.current) {
      editResolved.current = true;
      const needle = binding.application.bundleId;
      const match = installed.find(a => a.bundleId === needle) ?? installed.find(a => a.bundleId.toLowerCase() === needle.toLowerCase());
      if (match) setAppInfo({ name: match.name, path: match.path, bundleId: match.bundleId });
      else setAppMode("manual");
    }
  }, [binding, installed]);
  useEffect(() => {
    if (!binding) void detectApplication();
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
    try {
      // Precheck while the panel is still visible: a failing helper must produce a visible error.
      const helperPath = getPreferenceValues<{ helperPath: string }>().helperPath;
      await logDebug("pickPoint", `preflight status helperPath="${helperPath}"`);
      const preflight = await callHelper(helperPath, { protocolVersion: 1, command: "status" });
      await logDebug("pickPoint", `preflight ok=${preflight.ok} trusted=${preflight.ok ? preflight.data.accessibilityTrusted : "n/a"}`);
      if (!preflight.ok || !preflight.data.accessibilityTrusted) {
        await logDebug("pickPoint", "aborted: accessibility not trusted");
        await failure(new Error("PERMISSION_DENIED: Helper 尚无辅助功能权限。请先在 系统设置 → 隐私与安全性 → 辅助功能 中授权 Helper，再重试。"));
        return;
      }
      // The picking overlay must become key, so close the Raycast panel first (closeMainWindow exists in @raycast/api 1.104.5 types).
      await logDebug("pickPoint", "closing main window");
      await closeMainWindow({ clearRootSearch: true });
      await logDebug("pickPoint", `calling capture bundleId="${bundleId}" anchor="${anchor}"`);
      const response = await callHelper(helperPath, { protocolVersion: 1, command: "capture", bundleId, anchor });
      if (!response.ok) {
        await logDebug("pickPoint", `helper failed ${response.error.code}: ${response.error.message}`);
        await failure(new Error(`${response.error.code}: ${response.error.message}`));
        return;
      }
      const d = response.data as unknown as CaptureData; // parseResponse validated the capture success shape for command === "capture"
      await logDebug("pickPoint", `confirmed offset=(${d.offset.x},${d.offset.y}) anchor=${d.anchor} pid=${d.pid}`);
      setAnchor(d.anchor); setX(d.offset.x.toFixed(2)); setY(d.offset.y.toFixed(2));
      await showToast({ style: Toast.Style.Success, title: "偏移已填入，请保存规则" });
    } catch (e) {
      await logDebug("pickPoint", `exception: ${e instanceof Error ? (e.stack ?? e.message) : String(e)}`);
      await failure(e);
    } finally { interactiveSession.current = false; setCapturing(false); }
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
        <Action title={appMode === "dropdown" ? "手动输入 Bundle ID…" : "以 Logo 列表选择应用…"} icon={appMode === "dropdown" ? Icon.Pencil : appInfo ? { fileIcon: appInfo.path } : Icon.AppWindow} onAction={() => setAppMode(appMode === "dropdown" ? "manual" : "dropdown")} />
      </ActionPanel.Section>
      <ActionPanel.Section>
        <Action.SubmitForm title="保存" shortcut={binding ? { modifiers: ["cmd"], key: "s" } : undefined} onSubmit={submit} />
      </ActionPanel.Section>
    </ActionPanel>}>
    {error && <Form.Description title="Result" text={error} />}
    {binding ? <Form.Description title="ID (immutable)" text={binding.id} /> : <Form.TextField id="id" title="ID" placeholder="toggle-sidebar" />}
    <Form.TextField id="name" title="Name" defaultValue={binding?.name} />
    {appMode === "manual"
      ? <Form.TextField id="bundleId" title="App Bundle ID" placeholder="自动从激活应用获取，也可手动修改" value={bundleId} error={appError} onChange={value => { generation.current++; setDetecting(false); setBundleId(value); setAppError(undefined); scheduleAppLookup(value); }} />
      : <Form.Dropdown id="app" title="App (Bundle ID)" value={appInfo?.bundleId ?? (bundleId ? bundleId : "__detecting__")} onChange={value => {
        generation.current++; setDetecting(false); setAppError(undefined);
        if (value === "__manual__") { setAppMode("manual"); return; }
        if (value === "__detecting__") return;
        setBundleId(value);
        const app = installed.find(a => a.bundleId === value);
        if (app) setAppInfo({ name: app.name, path: app.path, bundleId: app.bundleId });
        else scheduleAppLookup(value);
      }}>
        {installed.map(app => <Form.Dropdown.Item key={app.bundleId} value={app.bundleId} title={app.name} keywords={[app.bundleId, "bundle id"]} icon={{ fileIcon: app.path }} />)}
        {appInfo && !installed.some(a => a.bundleId === appInfo.bundleId) && <Form.Dropdown.Item value={appInfo.bundleId} title={`${appInfo.name}（未安装）`} icon={{ fileIcon: appInfo.path }} />}
        {!appInfo && bundleId && !installed.some(a => a.bundleId === bundleId) && <Form.Dropdown.Item value={bundleId} title={`${bundleId}（未识别）`} icon={Icon.QuestionMark} />}
        {!appInfo && (detecting || !bundleId) && <Form.Dropdown.Item value="__detecting__" title={detecting ? `正在检测前台应用${"…".repeat(dots)}` : "正在检测前台应用…"} icon={Icon.MagnifyingGlass} />}
        <Form.Dropdown.Item value="__manual__" title="手动输入 Bundle ID…" icon={Icon.Pencil} />
      </Form.Dropdown>}
    {bundleId.trim() !== "" && <Form.Description title="已识别应用" text={appInfo ? `${appInfo.name} · ${appInfo.path}` : "未在已安装应用中找到；规则仍可保存，运行时会按该 Bundle ID 匹配"} />}
    <Form.Description title="快捷键" text={shortcut ? formatShortcut(shortcut) : "尚未设置"} />
    {shortcutError && <Form.Description title="快捷键提示" text={shortcutError} />}
    <Form.Dropdown id="anchor" title="Anchor" value={anchor} onChange={value => setAnchor(value as Anchor)}>{anchors.map(a => <Form.Dropdown.Item key={a} value={a} title={a} />)}</Form.Dropdown>
    <Form.TextField id="x" title="Offset X" value={x} onChange={setX} />
    <Form.TextField id="y" title="Offset Y" value={y} onChange={setY} />
    <Form.Checkbox id="enabled" label="启用规则（后台服务运行时生效）" defaultValue={binding?.enabled ?? true} />
    <Form.Description text="保存会更新已运行的后台服务；未启动服务时仅保存，不自动开始监听。" />
  </Form>;
}
