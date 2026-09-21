可以，我直接按这版 PRD 往下拆成“技术设计 + Swift 模块 + Milestone + GitHub Issues”，后面可以直接交给 Codex 开发。

:::writing{variant="document" id="29164" title="Codex TouchBar Monitor 技术设计与开发拆分"}
# Codex TouchBar Monitor
## Technical Design + Development Plan

版本：v1.0  
对应 PRD：Codex TouchBar Monitor PRD v1.0

---

# 1. 总体技术架构

```text
┌──────────────────────────────────────────────┐
│           CodexTouchBarMonitor.app           │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │ App Lifecycle / Settings               │  │
│  └────────────────────────────────────────┘  │
│                    │                         │
│       ┌────────────┼─────────────┐           │
│       ▼            ▼             ▼           │
│ Application    Codex Core    Persistent      │
│ Monitor        Services      Services         │
│                    │             │            │
│                    ▼             ▼            │
│              ExecutionMgr   NetworkMonitor    │
│              DecisionMgr    QuotaMonitor      │
│              InputMgr       CodexLauncher     │
│                    │             │            │
│                    └──────┬──────┘            │
│                           ▼                   │
│                  TouchBarController           │
│                    │            │             │
│                    ▼            ▼             │
│              Dynamic Area   Persistent Tray   │
└──────────────────────────────────────────────┘
```

---

# 2. 核心设计原则

### 2.1 状态驱动

UI 不主动猜状态。

所有 Touch Bar UI 均由统一：

```text
AppState
```

渲染。

### 2.2 Event Driven

Codex 执行状态通过 App Server 事件更新。

禁止通过高频轮询判断：

```text
Running
Completed
Decision
Failed
```

### 2.3 Persistent 与 Dynamic 完全解耦

```text
Persistent Tray
```

生命周期：

```text
macOS Login → Logout
```

而：

```text
Dynamic Area
```

生命周期由 Codex Execution / Decision 驱动。

---

# 3. 推荐工程目录

```text
CodexTouchBarMonitor/
├── App/
│   ├── CodexTouchBarMonitorApp.swift
│   ├── AppDelegate.swift
│   └── AppLifecycleController.swift
│
├── Models/
│   ├── AppState.swift
│   ├── ExecutionState.swift
│   ├── MonitoredExecution.swift
│   ├── DecisionRequest.swift
│   ├── InputSession.swift
│   ├── NetworkStatus.swift
│   └── QuotaStatus.swift
│
├── Codex/
│   ├── CodexConnectionManager.swift
│   ├── CodexAppServerClient.swift
│   ├── CodexEventAdapter.swift
│   ├── CodexExecutionDiscovery.swift
│   └── CodexRPCModels.swift
│
├── Execution/
│   ├── ExecutionManager.swift
│   └── ExecutionStore.swift
│
├── Decision/
│   ├── DecisionManager.swift
│   └── DecisionStore.swift
│
├── Input/
│   ├── TextInputController.swift
│   ├── InputSessionStore.swift
│   ├── HiddenInputPanel.swift
│   └── IMETextView.swift
│
├── Application/
│   └── ApplicationMonitor.swift
│
├── Persistent/
│   ├── NetworkMonitor.swift
│   ├── QuotaMonitor.swift
│   └── CodexLauncher.swift
│
├── TouchBar/
│   ├── TouchBarController.swift
│   ├── TouchBarPrivateBridge.swift
│   │
│   ├── Persistent/
│   │   ├── PersistentTrayController.swift
│   │   └── PersistentTrayView.swift
│   │
│   └── Dynamic/
│       ├── DynamicAreaController.swift
│       ├── DashboardView.swift
│       ├── DecisionSelectorView.swift
│       ├── DecisionView.swift
│       ├── TextInputTouchBarView.swift
│       └── TaskDetailView.swift
│
├── Settings/
│   ├── SettingsManager.swift
│   └── SettingsView.swift
│
├── Notifications/
│   └── NotificationManager.swift
│
└── Tests/
```

---

# 4. 核心状态模型

## AppState

```swift
struct AppState {
    var isCodexForeground: Bool

    var executions: [MonitoredExecution]
    var decisions: [DecisionRequest]

    var activeInputSession: InputSession?

    var networkStatus: NetworkStatus
    var quotaStatus: QuotaStatus

    var codexConnectionState: CodexConnectionState
}
```

所有 Touch Bar 页面只读取：

```text
AppState
```

---

# 5. Execution Model

```swift
struct ExecutionID: Hashable {
    let serverID: String
    let threadID: String
    let turnID: String
}
```

必须从第一版就保留：

```text
serverID
```

即使 MVP 只有一个 Codex App Server。

避免未来支持多个 Codex Instance 时重构主键。

---

## MonitoredExecution

```swift
struct MonitoredExecution: Identifiable {
    let id: ExecutionID

    var title: String
    var cwd: String?
    var repository: String?

    var state: ExecutionState

    var startedAt: Date
    var updatedAt: Date

    var acknowledged: Bool

    var activeDecisionID: String?
}
```

---

# 6. ExecutionState

```swift
enum ExecutionState {
    case running
    case waitingDecision
    case completed
    case failed
    case unknown
}
```

UI：

```text
running         → yellow
waitingDecision → flashing warning
completed       → green
failed          → red
unknown         → gray
```

---

# 7. ExecutionManager

职责：

```text
接收 Codex Event
↓
更新 ExecutionStore
↓
维护 monitored set
↓
发布 AppState
```

必须实现：

```swift
func discoverActiveExecutions()
func handleTurnStarted(...)
func handleTurnCompleted(...)
func handleTurnFailed(...)
func acknowledge(_ id: ExecutionID)
```

---

# 8. Execution 生命周期

```text
Turn Started
    ↓
Running
    ↓
┌───────────────┐
│               │
▼               ▼
Decision      Continue
│               │
▼               │
Running ◄────────┘
│
├── Completed
│      ↓
│  wait acknowledge
│      ↓
│   remove
│
└── Failed
       ↓
   wait acknowledge
       ↓
    remove
```

---

# 9. CodexConnectionManager

职责：

```text
启动 / 连接 app-server
保持连接
重连
RPC request/response
事件分发
```

接口建议：

```swift
protocol CodexConnectionManaging {
    func connect() async
    func disconnect()

    func sendRequest<T>(...)
    var events: AsyncStream<CodexEvent> { get }
}
```

---

# 10. CodexEventAdapter

不要让业务层直接理解原始 JSON-RPC。

例如原始事件：

```text
thread/status/changed
item/started
item/completed
tool/requestUserInput
command/requestApproval
```

统一转成：

```swift
enum CodexEvent {
    case executionStarted(...)
    case executionCompleted(...)
    case executionFailed(...)

    case decisionRequested(...)
    case decisionResolved(...)

    case quotaUpdated(...)
}
```

这样 Codex 协议变化只修改 Adapter。

---

# 11. DecisionManager

负责：

```text
Decision Queue
Approval
Permission
Option
Free Text
```

数据：

```swift
enum DecisionType {
    case approval
    case permission
    case options
    case text
}
```

---

# 12. DecisionRequest

```swift
struct DecisionRequest: Identifiable {
    let id: String

    let executionID: ExecutionID

    var type: DecisionType

    var prompt: String
    var options: [DecisionOption]

    var createdAt: Date
}
```

---

# 13. Decision UI 状态机

```text
0 decisions
   ↓
Dashboard

1 decision
   ↓
Auto show decision

>1 decisions
   ↓
Decision Selector
```

特殊情况：

如果当前用户主动进入 Task Detail：

```text
Decision arrives
```

不强制覆盖用户当前操作。

可以：

```text
⚠ badge
```

提醒。

---

# 14. Decision 安全规则

禁止：

```text
Approve All
```

禁止：

```text
自动进入 acceptForSession
```

任何高权限操作：

```text
必须一次点击对应一次操作
```

---

# 15. TextInputController

这是整个项目技术复杂度最高的模块之一。

目标：

```text
Codex 请求文本
↓
Touch Bar 展示输入框
↓
用户点击输入框
↓
实体键盘输入
↓
当前应用不切换
↓
Touch Bar 实时显示文本
↓
Enter 提交给 Codex
```

---

# 16. 输入实现建议

不要直接使用：

```text
CGEventTap
```

作为主要输入实现。

原因：

```text
中文 IME
Composition
Emoji
死键
输入法候选
```

都会非常麻烦。

推荐：

```text
Hidden Borderless NSPanel
+
NSTextView / NSTextField
+
standard NSTextInputClient
```

---

# 17. HiddenInputPanel

特点：

```text
不可见
无标题栏
不出现在 Dock
不改变用户屏幕布局
```

当用户点击 Touch Bar 输入框：

```text
makeKey()
```

让 macOS 输入系统将文字输入到隐藏 TextView。

TextView 内容实时同步：

```text
InputSession.text
```

再渲染到 Touch Bar。

---

# 18. 输入与“当前应用不切走”

需要区分：

```text
视觉前台应用
```

和：

```text
key window / first responder
```

项目目标是：

用户视觉上仍停留在：

```text
Safari / Zed / Ghostty
```

但输入焦点临时进入隐藏输入窗口。

Send / Cancel 后：

恢复之前窗口焦点。

需要保存：

```swift
weak var previousKeyWindow: NSWindow?
```

和：

```text
previous frontmost application
```

提交完成后恢复。

---

# 19. 输入模式 UI

```text
Sandbox │ ⌨ feature/runtime█ │ Cancel │ Send
```

输入区域至少包含：

```text
taskName
inputPreview
captureIndicator
cancel
send
```

---

# 20. IME 必测场景

测试至少包括：

```text
英文
中文拼音
中文候选选择
中英文混输
Emoji
Command+V
Command+A
Backspace
Option+Arrow
```

---

# 21. Persistent Tray 架构

```text
PersistentTrayController
   │
   ├── NetworkMonitor
   ├── QuotaMonitor
   └── CodexLauncher
```

必须独立于：

```text
CodexExecutionMonitor
```

即：

Codex 一个任务都没有：

Persistent Tray 仍正常。

---

# 22. TouchBarPrivateBridge

必须作为项目唯一接触 Private API 的地方。

接口例如：

```swift
protocol TouchBarPrivateBridging {
    func installPersistentTray(item: NSTouchBarItem)
    func removePersistentTray()
}
```

Private symbol lookup、Control Strip 注册等：

全部封装内部。

禁止：

```text
PersistentTrayController
```

直接调用私有函数。

---

# 23. Private API Fail-Safe

启动：

```text
Private API available?
```

是：

```text
Install tray
```

否：

```text
disable touchbar integration
```

但：

```text
App 不崩
Network Monitor 继续
Quota Monitor 继续
Codex integration 继续
```

方便调试未来 macOS 更新。

---

# 24. NetworkMonitor

不要把逻辑命名为：

```text
VPNMonitor
```

因为真正目标是：

```text
OpenAI Reachability
```

---

# 25. 网络检测算法

建议分两层。

### Layer 1

ICMP：

```text
ping chatgpt.com
```

优点：

容易得到 RTT。

### Layer 2

如果 ICMP 不通：

进行：

```text
TCP/HTTPS request
```

检测：

```text
443 reachable
```

---

# 26. Latency 数据

优先显示：

```text
ICMP RTT
```

如果只能通过 HTTPS 测试：

显示：

```text
HTTP RTT
```

内部保留：

```swift
enum LatencySource {
    case icmp
    case https
}
```

---

# 27. NetworkStatus

```swift
struct NetworkStatus {
    var reachable: Bool
    var latencyMs: Int?
    var source: LatencySource?
    var updatedAt: Date
}
```

---

# 28. Network Refresh

正常：

```text
10 sec
```

失败：

```text
3 sec
```

恢复连续 3 次：

```text
10 sec
```

避免频繁颜色抖动。

---

# 29. Network 颜色

默认：

```text
< 100ms
green

100 - 250ms
yellow

> 250ms
red

unreachable
red OFF
```

后续允许设置。

---

# 30. QuotaMonitor

职责：

```text
获取 Codex Weekly Limit
缓存
更新
stale 管理
```

只关心：

```text
7D / Weekly
```

---

# 31. QuotaStatus

```swift
struct QuotaStatus {
    var remainingPercent: Int?
    var resetAt: Date?
    var updatedAt: Date?
    var stale: Bool
}
```

---

# 32. Quota 获取策略

优先：

```text
account/rateLimits/updated event
```

其次：

```text
account/rateLimits/read
```

最后：

```text
缓存值
```

---

# 33. Quota 展示

正常：

```text
7D72%
```

无数据：

```text
7D--
```

stale：

建议通过：

```text
降低 opacity
```

而不是增加额外文字占空间。

---

# 34. CodexLauncher

接口：

```swift
func openCodex()
```

逻辑：

```text
find running app
     │
     ├── exists
     │    ↓
     │ activate
     │
     └── absent
          ↓
        launch
          ↓
        activate
```

---

# 35. Launcher 降级

如果 Codex Desktop 未安装：

显示一个轻量通知：

```text
Codex not installed
```

不得自动下载。

---

# 36. ApplicationMonitor

监听：

```text
NSWorkspace.didActivateApplicationNotification
```

维护：

```swift
var isCodexForeground: Bool
```

需要允许配置多个：

```text
Codex UI bundle IDs
```

避免未来 Codex Desktop bundle 变化。

---

# 37. Background Snapshot

事件：

```text
Codex foreground
→
Other app
```

执行：

```swift
await executionManager.discoverActiveExecutions()
```

只加入：

```text
running
waitingDecision
```

---

# 38. DynamicAreaController

负责决定当前应该展示哪种 Codex UI。

优先级：

```text
Active Input
>
Single Decision
>
Multiple Decisions
>
Task Dashboard
>
None
```

如果：

```text
None
```

则不给 Dynamic Area 注入 Codex UI。

---

# 39. 与其他 App Touch Bar 的关系

Persistent Tray：

```text
Control Strip private API
```

Dynamic Area：

第一阶段建议尽量避免全局覆盖别的 App Touch Bar。

更好的策略：

### 有 Decision / Active Tasks 时

使用最小的动态 Touch Bar accessory。

不要完全替换应用内容。

最终目标：

```text
App Native Controls
+
Codex Monitoring
+
Persistent Tray
```

---

# 40. 资源占用目标

后台无任务：

```text
CPU < 1%
```

内存：

```text
< 100MB
```

最好：

```text
< 60MB
```

---

# 41. 并发模型

推荐：

```text
Swift Concurrency
```

核心 Manager 尽量使用：

```swift
actor
```

例如：

```swift
actor ExecutionStore
actor DecisionStore
actor CodexAppServerClient
```

UI：

```text
@MainActor
```

---

# 42. 日志

使用：

```text
OSLog
```

日志类别：

```text
app
codex
execution
decision
input
touchbar
network
quota
```

禁止记录：

```text
用户完整 prompt
输入正文
secret
token
password
代码内容
```

---

# 43. Settings

第一版配置：

```text
Launch at Login

Network Status ON/OFF

Weekly Quota ON/OFF

Latency Refresh Interval

Maximum Visible Tasks

Auto Show Single Decision

Decision Notification Delay
```

---

# 44. 启动流程

```text
Application Start
     │
     ├── Load Settings
     │
     ├── Start Network Monitor
     │
     ├── Start Quota Monitor
     │
     ├── Install Persistent Tray
     │
     ├── Start Application Monitor
     │
     └── Connect Codex
```

注意：

```text
Persistent Tray
```

不等待 Codex 连接成功。

---

# 45. Codex 连接失败

例如未登录：

```text
Network 61ms
7D--
Codex Logo
```

仍然正常工作。

---

# 46. 测试策略

必须拆成：

```text
Unit Tests
Integration Tests
Manual Touch Bar Tests
```

---

# 47. Unit Tests

至少：

```text
Execution state transitions

acknowledge removal

new turn on existing thread

decision sorting

single vs multi decision

quota percentage conversion

network color calculation

task sorting
```

---

# 48. Integration Tests

模拟 Codex RPC：

```text
Turn Started
Decision
Resolve
Complete
```

验证：

```text
AppState
```

最终正确。

---

# 49. Touch Bar 手工测试

必须在真实 Touch Bar MacBook 上测试：

```text
跨应用切换
Safari
Finder
Ghostty
Zed
VS Code

Control Strip coexistence

多任务显示

Decision flashing

中文输入

焦点恢复

Codex launcher
```

模拟器不足以覆盖全部行为。

---

# 50. Milestone 1
## Persistent Foundation

目标：

先证明最关键技术风险：

> 能否永久显示右侧区域，同时不破坏其他应用 Touch Bar。

Issues：

### #1 Project Bootstrap

建立：

```text
Swift macOS app
LSUIElement
basic logging
settings
```

### #2 TouchBar Private Bridge

实现：

```text
Control Strip system tray injection
```

### #3 Persistent Tray UI

实现：

```text
Network │ Weekly │ Codex
```

静态 UI。

### #4 Network Monitor

实现：

```text
latency + reachability
```

### #5 Codex Launcher

实现：

```text
launch / activate Codex
```

### #6 Quota Prototype

验证独立读取：

```text
weekly quota
```

验收：

```text
Safari / Finder / Zed 等前台切换
Persistent Tray 始终存在
不破坏其他 Touch Bar 基础功能
```

---

# 51. Milestone 2
## Codex Connection

### #7 Codex App Server Client

实现：

```text
JSON-RPC connection
```

### #8 Event Adapter

把 RPC：

```text
→ CodexEvent
```

### #9 Execution Discovery

实现：

```text
active turns snapshot
```

### #10 Application Monitor

检测：

```text
Codex foreground/background
```

验收：

离开 Codex 时：

能够发现所有当前 Running Task。

---

# 52. Milestone 3
## Task Dashboard

### #11 Execution Store

实现：

```text
MonitoredExecution
```

生命周期。

### #12 Task State UI

支持：

```text
yellow
green
red
```

### #13 Task Sorting

支持：

```text
decision > failed > completed > running
```

### #14 Task Pagination

实现：

```text
+N
```

### #15 Acknowledge

点击 Completed / Failed：

```text
remove if no newer turn
```

验收：

多个 Codex 后台任务可以可靠跟踪。

---

# 53. Milestone 4
## Decision Queue

### #16 Approval Parsing

支持：

```text
command approval
file approval
permission
```

### #17 Decision Store

支持多个并发 Decision。

### #18 Single Decision UI

仅一个：

```text
自动展开
```

### #19 Multi Decision Selector

多个：

```text
先选任务
```

### #20 Decision Response

准确返回：

```text
server/thread/turn/request
```

### #21 Flashing State

实现警告闪烁。

验收：

多个任务同时请求 Approval：

可以逐个处理且不串任务。

---

# 54. Milestone 5
## Touch Bar Text Input

### #22 Input Session Model

实现：

```text
InputSession
```

### #23 Hidden Input Panel

建立：

```text
hidden NSTextInputClient
```

### #24 Keyboard Capture

用户点击输入框后：

```text
capture
```

### #25 Touch Bar Input Renderer

实时显示：

```text
typed text
```

### #26 Submit / Cancel

支持：

```text
Enter
Esc
```

### #27 Clipboard

支持：

```text
Cmd+A/C/V/X
```

### #28 Chinese IME

验证系统拼音等输入法。

### #29 Focus Restore

完成输入后：

恢复之前应用。

验收：

用户在 Safari 页面上：

无需切回 Codex 就能完成中文或英文文本回复。

---

# 55. Milestone 6
## Polish

### #30 Notifications

Decision / Failed。

### #31 Task Detail

显示：

```text
Running
duration
current activity
```

### #32 Open Task

跳转 Codex 对应 Task。

### #33 Settings UI

基础设置。

### #34 Launch at Login

实现。

### #35 Crash / reconnect handling

App Server 掉线恢复。

### #36 Private API fallback

私有 API 不可用时安全降级。

---

# 56. GitHub Labels

建议：

```text
area:touchbar
area:codex
area:execution
area:decision
area:input
area:network
area:quota
area:settings

type:feature
type:bug
type:refactor
type:test

priority:p0
priority:p1
priority:p2

risk:private-api
risk:ime
risk:codex-protocol
```

---

# 57. P0 Issues

以下必须视为 P0：

```text
#2 TouchBar Private Bridge

#6 Quota Prototype

#7 Codex App Server Client

#9 Execution Discovery

#20 Decision Response

#23 Hidden Input Panel

#28 Chinese IME
```

其中技术风险最高：

```text
Private Touch Bar API
Codex 多 Execution 状态发现
IME 不切应用输入
```

---

# 58. 第一开发顺序

不要一开始写完整业务。

推荐严格顺序：

```text
Step 1
Persistent Tray PoC

Step 2
Network + Launcher

Step 3
Quota PoC

Step 4
Codex App Server PoC

Step 5
Active Task Discovery

Step 6
Task Dashboard

Step 7
Decision

Step 8
Text Input

Step 9
IME

Step 10
Polish
```

---

# 59. 第一版 PoC 成功标准

只要做到：

```text
Safari Touch Bar 正常
+
最右侧始终出现：

63ms │ 7D72% │ Codex

+
Codex 图标可以启动 Codex
```

则 Persistent Architecture 技术路线成立。

---

# 60. 第二 PoC 成功标准

同时运行至少：

```text
3 个 Codex Tasks
```

离开 Codex 后：

```text
Touch Bar
```

正确显示：

```text
🟡 TaskA │ 🟡 TaskB │ 🟡 TaskC
```

任务完成后变：

```text
🟢
```

则 Monitoring Architecture 成立。

---

# 61. 第三 PoC 成功标准

Codex 请求：

```text
Approval
```

Touch Bar：

```text
Allow │ Deny
```

点击后：

Codex 立即继续。

则 Decision Architecture 成立。

---

# 62. 第四 PoC 成功标准

Codex：

```text
Enter branch name:
```

用户当前仍停留 Safari。

点击 Touch Bar 输入框。

键入：

```text
功能分支测试
```

Touch Bar 实时显示。

Enter。

Codex 收到：

```text
功能分支测试
```

Safari 重新获得输入焦点。

则整个项目最核心交互闭环成立。

---

# 63. Definition of Done

V1.0 必须满足：

```text
✓ Persistent Network

✓ Persistent Weekly Quota

✓ Persistent Codex Launcher

✓ App Touch Bar coexistence

✓ Multiple Active Executions

✓ Running / Complete / Failed

✓ Acknowledge

✓ Single Decision

✓ Multi Decision Queue

✓ Approval Response

✓ Structured Option Selection

✓ Free Text Input

✓ Chinese IME

✓ Keyboard Focus Restore

✓ App Server Reconnect

✓ Login Startup

✓ Private API Safe Fallback
```

---

# 64. 最终开发目标

项目不是：

```text
Touch Bar 上放几个 Codex 快捷键
```

而是构建一个：

> **Codex Agent 的 macOS 后台控制平面。**

它将：

```text
状态
决策
输入
额度
网络
导航
```

统一压缩进 Touch Bar。

目标体验：

```text
当前正在做自己的工作
        │
        ▼
Touch Bar 告诉我 Agent 状态
        │
        ├── 不需要我 → 不打扰
        │
        └── 需要我
              │
              ▼
         直接在 Touch Bar
         处理并继续工作
```
:::

建议直接从 **Milestone 1 的 Persistent Tray PoC** 开始开发，因为它同时验证这个项目最大的不确定性：**私有 Control Strip API 在你当前 macOS + M1 Touch Bar 机器上是否能稳定和其他应用共存**。只要这一关过了，后面的 Codex 状态机和交互基本都是正常的 Swift 工程问题。