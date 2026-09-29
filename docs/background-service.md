# AppBind 后台服务

## 用户可见行为

保存规则不自动启动服务。Raycast 的 AppBind Background Service 命令提供显式启动（真实点击确认）、停止、状态、重载。只在服务正在运行时，保存/启停/删除规则会通知重载；保存数据的 SHA-256 必须与服务加载结果一致，才提示已加载生效。同步失败不回滚已经保存的文件，而是提示「已保存，服务同步失败」。规则 enabled 与服务 running 是不同状态。

如果启动请求超时或控制进程异常，不要仅凭启动报错断定服务未运行；使用状态查询并显式停止。服务端拒绝未完成的启动握手并在响应发送失败时清理，但网络/进程最终确认不是跨进程原子事务。

服务不会安装登录项，不自动弹系统授权，不提升权限，不主动激活目标 App。停止后不自动重启。权限不够、安全输入启用或事件监听失效时停止执行，需要用户查看状态并重新加载/启动。

## 控制协议

独立 argv 入口，与现有 stdin JSON 诊断协议分离：

```text
appbind-helper service-status --directory ABS_SUPPORT_DIR
appbind-helper service-start --directory ABS_SUPPORT_DIR
appbind-helper service-reload --directory ABS_SUPPORT_DIR
appbind-helper service-stop --directory ABS_SUPPORT_DIR
```

`service-start` 是明确的监听/执行授权操作，请勿用作无副作用探针。支持目录应是 Raycast environment.supportPath，包含 ConfigStore 写出的 config.json；不要把示例配置当真实目标使用。服务通过同用户本地 IPC 控制；不根据可伪造的 PID 文件杀进程。

响应 stdout 恰好一个换行结尾 JSON，不带 protocolVersion：

```json
{"ok":true,"data":{"running":false,"executionEnabled":false,"accessibilityTrusted":false,"inputMonitoringTrusted":false,"enabledBindings":0,"configDigest":null,"lastError":null,"pid":null}}
```

失败 exit 1，`{"ok":false,"error":{"code":"...","message":"..."}}`。成功 exit 0。Raycast 无 shell 调用，限制1MiB合计输出，启动15秒/其余5秒超时。字段形状、状态关系、摘要与退出码均严格校验。

服务读取有限大小、非符号链接、同用户的配置文件。配置解析失败停止使用旧规则，不继续在错误配置下执行。目录/锁/socket 进行所有权与权限校验。此信任边界是本地同用户，不声称抵抗已能修改该用户文件或注入其进程的攻击者。

## 输入与执行边界

- App 范围按前台 bundle ID/PID 匹配，而不是激活目标 App。
- 未匹配按键放行；匹配按键的重复、按下/松开需要配对处理。
- 工作任务串行，不在事件 tap 回调里做耗时 AX 查询。
- 等待触发键和修饰键释放，用户输入干预、App/窗口变化或配置重载取消任务。
- 标准、非最小化、非模态窗口；读取 AX 实时几何，目标点在窗口与屏幕内。
- AX 命中归属与 CG 窗口层级检查必须通过；缺失元数据拒绝执行，不靠 PID + 相似矩形猜窗口。
- 手动停止时会短暂等待已经吞掉的按键释放，再退出监听。若按键长时间不释放、权限撤回或 tap 已失效，无法保证继续吞掉后续物理 key-up；不补发模拟 key-down。
- 点击 down/up 成对发送；只在没有用户干预时尝试恢复指针。不能保证 WindowServer、目标 App 和检查过程为一个原子事务，瞬时窗口变化仍是必须人工评估的残余风险。
- 缺少 AXWindowNumber 时，允许受限替代映射：AX 窗口列表中只能有一个与聚焦窗口几何完全相同的窗口；CG 列表中同 PID、普通层级、可见且同几何的窗口也必须唯一，并对应触发时 CG ID。仍要求 AX 命中同窗、跨阶段 CFEqual 一致、无遮挡。该推断不是系统直接提供的身份保证；多窗口同几何、属性缺失或不一致拒绝执行。存在但错误的 AXWindowNumber 不使用替代映射。标准 AX 子角色、命中属性、安全输入和系统保留键等限制仍适用。
- 旧 stdin `execute` 仍拒绝，避免诊断脚本或任意一次性请求突然产生输入事件。

## 人工验收（未执行）

1. 先在无副作用的测试窗口配置点位，确认服务未运行时所有键保持原行为。
2. 用户授权后显式启动；状态必须就绪，绑定应仅在目标 App 前台有效。
3. 测试重复按住、松键、额外按键、移动鼠标、持鼠标键、切App、切同App窗口、窗口移动/遮挡/模态以及跨屏。
4. 服务停止后不能继续产生新点击；权限撤回、tap禁用、配置损坏应停止执行。
5. 启停/删除规则即时重载，服务摘要与当前文件一致；坏文件不沿用旧配置。
6. 创建两个控制器并发启动、控制进程失败/退出、长supportPath、服务残留socket恢复。

自动测试不得发送真实鼠标事件或自动启动全局监听；构建/纯状态机/文件与协议测试不等同于上述实机验收。
