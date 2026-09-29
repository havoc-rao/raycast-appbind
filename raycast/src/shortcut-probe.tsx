import { Action, ActionPanel, Detail, Icon, Keyboard, useNavigation } from "@raycast/api";
import { useState } from "react";
import { Modifier } from "./config";
import { allProbeShortcuts, ProbeShortcut, probeReport, probeShortcutId, sampleShortcuts } from "./shortcut-probe-model";

const modifierMap: Record<Modifier, Keyboard.KeyModifier> = { control: "ctrl", option: "opt", shift: "shift", command: "cmd" };
const fullSet = allProbeShortcuts();

export default function ShortcutProbe() {
  const { pop } = useNavigation();
  const [full, setFull] = useState(false);
  const [candidate, setCandidate] = useState<ProbeShortcut>();
  const [confirmed, setConfirmed] = useState<string>();
  const [events, setEvents] = useState<string[]>([]);
  const shortcuts = full ? fullSet : sampleShortcuts;
  function record(text: string) {
    setEvents(previous => [`${new Date().toISOString()}  ${text}`, ...previous].slice(0, 40));
  }
  function capture(shortcut: ProbeShortcut) {
    setCandidate(shortcut);
    setConfirmed(undefined);
    record(`MATCH ${probeShortcutId(shortcut)}`);
  }
  function confirm() {
    if (!candidate) { record("CONFIRM rejected: no candidate"); return; }
    setConfirmed(probeShortcutId(candidate));
    record(`CONFIRM ${probeShortcutId(candidate)} (memory only)`);
  }
  const mode = full ? "540 combinations" : "5 representative combinations";
  const markdown = `# Raycast 原生快捷键实验\n\n**不调用 Helper · 不保存配置 · 不注册全局热键**\n\n## ${confirmed ? "已确认（仅本页）" : "等待录制 / 可反复重录"}\n\n当前候选：**${candidate ? probeShortcutId(candidate) : "尚无输入"}**\n\n确认结果：**${confirmed ?? "—"}**\n\n模式：**${mode}**\n\n请先关闭操作菜单，直接按以下组合，观察候选及 MATCH 记录：\n\n- Ctrl+Alt+K\n- Cmd+K（可能打开 Raycast 操作菜单）\n- Cmd+S\n- Cmd+W（可能关闭当前页面）\n- Shift+K\n\n**Enter** 确认；**Esc** 使用 Raycast 默认返回/退出。前两个 Action 专门留给确认与取消，不用于捕获组合键。\n\n在操作菜单中可切换 540 组合模式或复制报告。菜单点击也会产生回调，不能当作按键捕获成功的证据。仅按修饰键不会显示预览；没有记录不代表按键没被系统处理。\n\n## 最近回调（最多 40 条）\n\n\`\`\`text\n${events.join("\n") || "尚无回调"}\n\`\`\``;
  return <Detail navigationTitle="快捷键录制实验（不保存）" markdown={markdown} actions={
    <ActionPanel>
      <Action title="确认候选（仅实验）" icon={Icon.Checkmark} onAction={confirm} />
      <Action title="取消实验并返回" icon={Icon.XMarkCircle} onAction={pop} />
      <ActionPanel.Section title="实验控制">
        <Action title={full ? "切换为 5 组基础测试" : "切换为 540 组完整测试"} onAction={() => {
          setFull(!full); setCandidate(undefined); setConfirmed(undefined); setEvents([]);
        }} />
        <Action title="清空本页记录" onAction={() => { setCandidate(undefined); setConfirmed(undefined); setEvents([]); }} />
        <Action.CopyToClipboard title="复制实验报告" content={probeReport(mode, events)} />
      </ActionPanel.Section>
      <ActionPanel.Section title="候选匹配（请用键盘测试，不要点击）">
        {shortcuts.map(shortcut => <Action key={probeShortcutId(shortcut)} title={`匹配 ${probeShortcutId(shortcut)}`}
          shortcut={{ key: shortcut.key as Keyboard.KeyEquivalent, modifiers: shortcut.modifiers.map(m => modifierMap[m]) }}
          onAction={() => capture(shortcut)} />)}
      </ActionPanel.Section>
    </ActionPanel>
  } />;
}
