# 0.2.0 实现记录

开发位置：build host `<repository-root>`。
本轮用户指令优先：先补代码；测试不依赖实体 Touch Bar。
此前 STATUS 文档记录的是 0.1.x 历史，不代表本版实现情况。

## 代码范围

| 层 | 文件 | 内容 |
|---|---|---|
| 纯状态 | MonitorCore/Execution.swift | turn 身份、状态、排序、确认、断线失效、审批 wire values |
| 传输 | MonitorCore/WebSocketCodec.swift | 掩码、长度边界、分片、ping/pong、关闭 |
| RPC | MonitorApp/CodexAppServerClient.swift | stdio / Unix proxy WebSocket、握手校验、连接代次、超时、响应路由 |
| 执行 | MonitorApp/ExecutionManager.swift | loaded 分页、订阅、活动轮次发现、事件更新、决策队列、重连 |
| 交互 | MonitorApp/DashboardController.swift | 桌面与 Touch Bar、详情、分页、审批、选项、多问题、演示 |
| 输入 | MonitorApp/TextInputController.swift | nonactivating NSPanel、NSTextView、marked text、防误提交、焦点恢复 |
| 设置 | MonitorApp/SettingsController.swift | 配置 UI、登录启动、延迟通知 |
| 验证 | MonitorApp/SelfChecks.swift、scripts/mock_app_server.py | 无实体 Touch Bar 的原生集成与输入检查 |

## 协议发现

旧版本向 daemon control socket 直接写 JSON，所以初始化超时。
本机 daemon 实测先响应 HTTP 101 WebSocket Upgrade；本版通过 proxy 建立 RFC 6455 帧通道后 initialize 成功。
额度继续由独立 app-server 读取，执行发现只连接指定 daemon。

`thread/read` 不建立订阅，因此执行层仅对 `thread/loaded/list` 中的任务调用 `thread/resume`，
不附带 model、cwd、sandbox、approvalPolicy 等覆盖参数；使用 excludeTurns 和 thread/turns/list
避免拉取完整历史/消息正文。任务状态由事件更新，未高频轮询运行状态。

回送校验四层身份与连接代次。数字/字符串 request ID 不混淆。发送后按钮禁用，等待 resolved；
断线会清除队列并标记运行状态 unknown，避免离线状态下误批。
权限响应只包含请求的权限，scope 固定为 turn；不隐式 acceptForSession。

## 验证与边界

- Release 编译、签名验证及 ZIP 打包通过。
- 核心断言：38 项；含状态排序、旧轮次确认、服务器隔离、断线、额度、网络、WebSocket 分片/掩码。
- 模拟 RPC 集成：11 项；含 string/numeric ID、并发决策隔离、事件完成、新轮次、EOF、错误、重连。
- AppKit UI：7 项；多决策选择、拒绝、原生中文/Emoji 组合输入、组合未结束禁止发送、提交、确认移除。
- 真实 daemon：WebSocket 初始化及 loaded list 成功；12 秒冒烟发现并订阅 1 个真实任务，额度独立读取正常。没有批准任何真实请求。
- 本轮自动检查和构建日志：`work/tests-0.2.0.log`、`work/build-0.2.0.log`、`work/smoke-0.2.0.log`。
- 合成输入测试不覆盖真实系统拼音候选 UI、跨应用/跨 Space 焦点或物理 Touch Bar 布局。
- 打包为 adhoc 签名，通知系统权限和登录启动系统设置仍由 macOS 管理。
- 本版按当前本机 CLI schema 实现；不支持的协议请求交给 Codex。
- 无实体 Touch Bar 是允许的测试环境，不作为后续开发阻塞项。
