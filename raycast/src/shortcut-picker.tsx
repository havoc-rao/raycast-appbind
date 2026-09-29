import { Action, ActionPanel, Icon, Keyboard, List, Toast, closeMainWindow, getPreferenceValues, showToast, useNavigation } from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { Modifier } from "./config";
import { formatShortcut } from "./shortcut";
import { PickerShortcut, captureEnabled, pickerShortcuts, searchShortcuts } from "./shortcut-picker-model";
import { ShortcutData, callHelper } from "./transport";

const modifierMap: Record<Modifier, Keyboard.KeyModifier> = { control: "ctrl", option: "opt", shift: "shift", command: "cmd" };

export function ShortcutPicker({ current, onConfirm }: {
  current?: ShortcutData;
  onConfirm: (shortcut: ShortcutData, isActive: () => boolean) => Promise<void>;
}) {
  const { pop } = useNavigation();
  const [query, setQuery] = useState("");
  const [candidate, setCandidate] = useState<PickerShortcut | undefined>(current);
  const [selectedId, setSelectedId] = useState<string | null>(current ? "candidate" : "help");
  const [error, setError] = useState<string>();
  const [busy, setBusy] = useState(false);
  const locked = useRef(false);
  const alive = useRef(true);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  const recording = captureEnabled(query);
  const results = recording ? [] : searchShortcuts(query);
  const selected = recording ? (selectedId === "candidate" ? candidate : undefined)
    : results.find(item => formatShortcut(item) === selectedId);

  function capture(shortcut: PickerShortcut) {
    if (locked.current || !recording) return;
    setCandidate(shortcut); setSelectedId("candidate"); setError(undefined);
  }
  async function commit(shortcut: ShortcutData | undefined) {
    if (locked.current) return;
    if (!shortcut) { setError("请先按下组合键，或输入文字选择快捷键。"); return; }
    locked.current = true; setBusy(true); setError(undefined);
    try {
      await onConfirm(shortcut, () => alive.current);
      if (alive.current) pop();
    } catch (e) {
      if (alive.current) setError(e instanceof Error ? e.message : String(e));
    } finally { locked.current = false; if (alive.current) setBusy(false); }
  }
  async function nativeRecord() {
    if (locked.current) return;
    locked.current = true; setBusy(true); setError(undefined);
    try {
      const helperPath = getPreferenceValues<{ helperPath: string }>().helperPath;
      const status = await callHelper(helperPath, { protocolVersion: 1, command: "status" });
      if (!status.ok) throw new Error(`${status.error.code}: ${status.error.message}`);
      await closeMainWindow();
      const response = await callHelper(helperPath, { protocolVersion: 1, command: "record-shortcut" });
      if (!alive.current) return;
      if (!response.ok) {
        if (response.error.code === "USER_CANCELLED") return;
        throw new Error(`${response.error.code}: ${response.error.message}`);
      }
      const shortcut = response.data as unknown as ShortcutData;
      await onConfirm(shortcut, () => alive.current);
      if (alive.current) pop();
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      if (alive.current) { setError(message); await showToast({ style: Toast.Style.Failure, title: "快捷键未回填", message }); }
    } finally { locked.current = false; if (alive.current) setBusy(false); }
  }
  const actions = <ActionPanel>
    <Action title="确认并回填" icon={Icon.Checkmark} onAction={() => commit(selected)} />
    <Action title="取消并返回" icon={Icon.XMarkCircle} onAction={() => { if (!locked.current) pop(); }} />
    <ActionPanel.Section title="其他方式">
      <Action title="使用原生录制窗口…" icon={Icon.Keyboard} onAction={nativeRecord} />
      <Action title="清空搜索并重新录制" onAction={() => {
        if (locked.current) return;
        setQuery(""); setCandidate(undefined); setSelectedId("help"); setError(undefined);
      }} />
    </ActionPanel.Section>
    {recording && <ActionPanel.Section title="录制组合键">
      {pickerShortcuts.map(shortcut => <Action key={formatShortcut(shortcut)} title={`录制 ${formatShortcut(shortcut)}`}
        shortcut={{ key: shortcut.key as Keyboard.KeyEquivalent, modifiers: shortcut.modifiers.map(m => modifierMap[m]) }}
        onAction={() => capture(shortcut)} />)}
    </ActionPanel.Section>}
  </ActionPanel>;
  const instructions = `# ${recording ? "按下组合键" : "手动选择快捷键"}\n\n${recording ? "直接按组合键更新候选，可反复重录，再按 Enter 确认。" : "选择左侧匹配项，按 Enter 确认。输入文字期间暂停按键捕获，避免干扰搜索；清空搜索恢复录制。"}\n\n也可输入：\n- cmd k / command+k / ⌘K\n- ctrl alt k / ⌃⌥K\n- shift 7\n- k（列出所有 K 组合）\n\n**⌘K、⌘W 已知会被 Raycast 抢占，请手动输入 cmd k / cmd w。** 其他系统组合也可能被抢占。\n\n仅支持字母/数字 + 至少一个修饰键。仅按修饰键没有预览。若要手输大写字符，请用小写，或先输入空格进入手动模式，避免 Shift+字母被录制。\n\nEsc 返回不回填。确认后仍需在表单保存。${error ? `\n\n## 未回填\n${error}` : ""}`;
  return <List isShowingDetail isLoading={busy} filtering={false} searchText={query}
    navigationTitle="设置快捷键 · 录制或输入"
    searchBarPlaceholder="直接按组合键，或输入 cmd k / ctrl alt k / ⌘K"
    onSearchTextChange={text => {
      if (locked.current) return;
      setQuery(text); setError(undefined);
      const first = searchShortcuts(text)[0];
      setSelectedId(captureEnabled(text) ? (candidate ? "candidate" : "help") : first ? formatShortcut(first) : "help");
    }} selectedItemId={selectedId ?? undefined} onSelectionChange={setSelectedId} actions={actions}>
    {recording && candidate && <List.Item id="candidate" title={formatShortcut(candidate)} subtitle="当前候选 · Enter 确认" icon={Icon.Keyboard}
      actions={actions} detail={<List.Item.Detail markdown={instructions} />} />}
    {!recording && results.map(shortcut => <List.Item id={formatShortcut(shortcut)} key={formatShortcut(shortcut)} title={formatShortcut(shortcut)}
      icon={Icon.Keyboard} actions={actions} detail={<List.Item.Detail markdown={`# ${formatShortcut(shortcut)}\n\n${instructions}`} />} />)}
    {(recording || results.length === 0) && <List.Item id="help" title={recording ? "等待按键，或在搜索框输入" : "没有匹配的组合键"}
      subtitle={recording ? "⌘K / ⌘W 请手动输入" : "例如 cmd k · 不支持 F1 或多段快捷键"}
      icon={Icon.Info} actions={actions} detail={<List.Item.Detail markdown={instructions} />} />}
  </List>;
}
