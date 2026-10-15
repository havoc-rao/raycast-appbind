import { Action, ActionPanel, Icon, List } from "@raycast/api";
import HelperStatus from "./helper-status";
import ShortcutProbe from "./shortcut-probe";

// Release staging replaces this module with a null component, so diagnostic
// views are excluded from the production dependency graph entirely.
export function DebugMenu() {
  return (
    <List.Section title="开发与诊断">
      <List.Item
        title="Helper Status"
        subtitle="Helper 状态、无点击诊断与调试日志"
        icon={Icon.Info}
        keywords={["helper", "status", "诊断", "日志"]}
        actions={<ActionPanel><Action.Push title="Open Helper Status" target={<HelperStatus />} /></ActionPanel>}
      />
      <List.Item
        title="Test Native Shortcut Recording"
        subtitle="实验性 Raycast 原生快捷键录制"
        icon={Icon.Keyboard}
        keywords={["shortcut", "recording", "快捷键", "录制"]}
        actions={<ActionPanel><Action.Push title="Open Shortcut Recording Test" target={<ShortcutProbe />} /></ActionPanel>}
      />
    </List.Section>
  );
}
