import { Action, ActionPanel, Icon, List } from "@raycast/api";
import ManageBindings from "./manage-bindings";
import CreateBinding from "./create-binding";
import BackgroundService from "./background-service";
import { DebugMenu } from "./debug-menu";

export default function AppBind() {
  return (
    <List navigationTitle="APPBIND" searchBarPlaceholder="搜索 AppBind 功能">
      <List.Section title="AppBind">
        <List.Item
          title="Manage Bindings"
          subtitle="管理、编辑和启停应用规则"
          icon={Icon.List}
          keywords={["manage", "bindings", "规则", "管理"]}
          actions={<ActionPanel><Action.Push title="Open Manage Bindings" target={<ManageBindings />} /></ActionPanel>}
        />
        <List.Item
          title="Create Binding"
          subtitle="为应用创建快捷键规则"
          icon={Icon.Plus}
          keywords={["create", "binding", "创建", "规则"]}
          actions={<ActionPanel><Action.Push title="Open Create Binding" target={<CreateBinding />} /></ActionPanel>}
        />
        <List.Item
          title="Background Service"
          subtitle="查看状态，手动启动、停止或重启后台服务"
          icon={Icon.Gear}
          keywords={["service", "后台", "服务", "状态"]}
          actions={<ActionPanel><Action.Push title="Open Background Service" target={<BackgroundService />} /></ActionPanel>}
        />
      </List.Section>
      <DebugMenu />
    </List>
  );
}
