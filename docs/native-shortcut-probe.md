# Raycast 原生 Action 快捷键录制实验

## 范围

独立命令 `Test Native Shortcut Recording`，不替换现有设置快捷键入口，不启动 Helper，不读写绑定配置，不全局监听。所有候选和记录仅存于该页面 React 状态，退出后可能丢失。

默认仅声明5组快捷键；操作菜单可切换540组。使用 Detail + Action.shortcut，前两个Action保留给确认/取消，避免默认主次Action快捷键污染采样组合。不能监测单独修饰键或keyUp。

## 实机验证

使用现有开发导入流程更新扩展，然后在Raycast打开 `Test Native Shortcut Recording`：

1. 保持操作菜单关闭，按 Ctrl+Alt+K；候选应更新并出现 MATCH。
2. 换按 Cmd+S；候选应替换，不应自动确认。
3. 按 Enter；应出现 CONFIRM，并明确仅在本页确认。
4. 分别测试 Cmd+K、Cmd+W、Shift+K：记录是否打开菜单、关闭页面、无反应，或实际收到 MATCH。页面被关闭后重新打开继续。
5. 用操作菜单复制报告。注意：点击菜单中的“匹配”也会触发同一回调，不能据此证明键盘可用。
6. 基础测试成功后，切换540组模式，关闭菜单，重复测试并观察卡顿。
7. 测试Esc是否正确退出，再回到现有表单，确认原录制功能未受影响。

| 测试项 | 待观察 |
| --- | --- |
| Ctrl+Alt+K | 无菜单时是否收到MATCH |
| Cmd+S | 与Raycast宿主动作的优先级 |
| Cmd+K | 是否先打开操作菜单 |
| Cmd+W | 是否先关闭Raycast页面 |
| Shift+K | 仅Shift组合是否被允许/正确匹配 |
| Enter / Esc | 确认与默认返回 |
| 540组 | 原生渲染负担、匹配可靠性 |

## 证据边界

类型检查与构建只证明公开API签名可用，不能证明Raycast运行时接受每个组合，也不能证明优先级和性能。MATCH只证明对应Action回调执行，API不提供回调来源（键盘或鼠标），因此需要人工保持菜单关闭测试。尚未进行实机按键验收，不应替换现有原生录制实现。

参考：
- https://developers.raycast.com/api-reference/keyboard
- https://developers.raycast.com/api-reference/user-interface/action-panel
