可以，下面给你一版**重新整合后的完整 PRD**。这版不是补丁式更新，而是把之前讨论的多任务监控、决策队列、Touch Bar 文本输入、永久网络/额度区域、Codex 快捷入口和私有 API 约束统一到一个基线里，后续可以直接拿它拆架构和开发任务。

:::writing{variant="document" id="74018" title="Codex TouchBar Monitor PRD v1.0"}
# Codex TouchBar Monitor

**Product Requirements Document**

版本：v1.0  
平台：macOS / MacBook Pro Touch Bar  
产品类型：Codex 后台任务监控与交互工具  
分发方式：GitHub Release / Homebrew Cask  
核心实现：Swift + AppKit + Touch Bar Private API + Codex App Server

---

# 1. 产品定位

Codex TouchBar Monitor 是一个运行在 macOS 上的 Codex 辅助工具，将 MacBook Pro Touch Bar 转化为：

> **Codex 后台任务状态监控、用户决策、文本输入、额度与网络状态展示的一体化控制面板。**

产品不替代 Codex Desktop 主界面。

产品主要解决：

> 当用户让一个或多个 Codex Agent 在后台执行任务，并切换到浏览器、IDE、终端、文档等其他应用后，如何无需频繁返回 Codex，就能持续知道任务状态，并在 Codex 需要人工介入时直接完成交互。

---

# 2. 核心使用场景

用户同时启动多个 Codex 开发任务：

```text
Sandbox      Running
UMDK         Running
openEuler    Running
```

随后用户切换到 Safari。

Touch Bar：

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Safari Controls │ 🟡 Sand │ 🟡 UMDK │ 🟡 OE │ 63ms │ 7D72% │ ◉ │
└─────────────────────────────────────────────────────────────────────┘
```

随后：

```text
Sandbox      Completed
UMDK         Needs Decision
openEuler    Running
```

Touch Bar：

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Safari Controls │ 🟢 Sand │ ⚠ UMDK │ 🟡 OE │ 61ms │ 7D71% │ ◉ │
└─────────────────────────────────────────────────────────────────────┘
```

因为只有一个任务需要决策，自动进入：

```text
┌─────────────────────────────────────────────────────────────────────┐
│ UMDK │ ⚠ Apply patch? │ Apply │ Reject │ 61ms │ 7D71% │ ◉ │
└─────────────────────────────────────────────────────────────────────┘
```

用户直接在 Touch Bar 点击：

```text
Apply
```

UMDK 继续运行。

之后 Sandbox 请求用户输入：

```text
Enter branch name:
```

Touch Bar：

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Sandbox │ ⌨ feature/runtime█ │ Cancel │ Send │ 58ms │ 7D71% │ ◉ │
└─────────────────────────────────────────────────────────────────────┘
```

用户不需要切换回 Codex。

直接使用实体键盘输入。

按 Enter。

Codex 收到输入并继续运行。

---

# 3. 产品核心原则

## 3.1 监控 Execution，而不是历史 Thread

系统不维护完整 Codex Thread 历史。

系统只关注：

```text
当前正在执行或需要用户处理的 Execution
```

唯一执行实例：

```text
threadId + turnId
```

同一个 Thread：

```text
Turn 17 → Completed
Turn 18 → Running
```

必须视为两个不同 Execution。

---

# 3.2 只监控真正活动的任务

历史：

```text
Idle
Completed + 已确认
Failed + 已确认
```

不应继续存在于 Touch Bar。

Touch Bar 任务区只包含：

```text
Running
Waiting Decision
Completed 未确认
Failed 未确认
```

---

# 3.3 Touch Bar 是后台控制面板

当用户正在使用 Codex：

完整信息本来就在屏幕上。

当用户切换到其他应用：

Touch Bar 才承担：

```text
后台任务监控
+
人工决策入口
```

---

# 3.4 系统状态永久存在

以下三个项目与 Codex 是否运行完全无关：

```text
OpenAI 网络质量
Codex 周额度
Codex Launcher
```

它们必须永久出现在 Touch Bar 最右侧。

---

# 3.5 不破坏其他应用 Touch Bar

Safari、Finder、IDE 等应用原生 Touch Bar 仍应正常工作。

本项目不能：

```text
完全接管 Touch Bar
```

而应：

```text
扩展 Touch Bar
```

---

# 4. Touch Bar 总体架构

Touch Bar 分成两类区域。

```text
┌──────────────────────────────────────────────────────────────────────┐
│          Application / Codex Dynamic Area       │ Persistent Area    │
├─────────────────────────────────────────────────┼────────────────────┤
│ App UI / Codex Tasks / Decisions / Input        │ 61ms │7D72%│Codex │
└──────────────────────────────────────────────────────────────────────┘
```

---

# 5. Persistent Area

Persistent Area 永久存在。

固定顺序：

```text
Network
Weekly Quota
Codex Launcher
```

例如：

```text
🟢 61ms │ 7D72% │ ◉
```

Codex Launcher 必须是最右元素。

---

# 6. Persistent Area 生命周期

以下所有情况都必须显示：

```text
Codex 未启动
Codex 已启动
没有 Codex Thread
存在多个 Codex Thread
没有 Running Task
正在运行多个 Task
Safari 前台
Finder 前台
IDE 前台
```

即：

```text
PersistentArea.lifecycle = macOS Login Session
```

而不是：

```text
Codex Process Lifecycle
```

---

# 7. Persistent Area 技术要求

普通前台应用的 `NSTouchBar` 不适合作为永久全局状态入口。

因此 Persistent Area 使用：

```text
Touch Bar Control Strip / System Tray Private API
```

本项目明确接受该技术路线。

Private API 必须封装：

```text
TouchBarPrivateBridge
```

业务层不得直接依赖 Private API。

---

# 8. Control Strip 插槽策略

网络、额度和 Codex 图标不建议注册为三个独立 Control Strip Item。

应实现为：

```text
1 个 System Tray Item
```

内部：

```text
PersistentTrayView
├── NetworkStatus
├── WeeklyQuota
└── CodexLauncher
```

优点：

```text
减少系统 Control Strip Slot 占用
降低与其他系统按钮冲突
统一布局
```

---

# 9. Dynamic Area

Dynamic Area 根据状态变化。

可能包含：

```text
Task Dashboard
Decision Selector
Decision View
Text Input
Task Detail
```

---

# 10. Foreground Mode

如果 Codex/ChatGPT 是当前前台应用：

普通 Running Task 不需要在 Dynamic Area 重复显示。

因此默认：

```text
当前应用 UI             │ 61ms │7D72%│◉
```

但：

```text
Decision
```

仍可以抢占展示。

---

# 11. Background Mode

当：

```text
Codex/ChatGPT
→
其他应用
```

发生时：

系统立即执行：

```text
Snapshot Active Executions
```

只获取：

```text
Running
WaitingOnApproval
WaitingOnUserInput
```

生成：

```text
MonitoredExecutionSet
```

---

# 12. Application Monitor

模块：

```text
ApplicationMonitor
```

负责监听：

```text
frontmostApplication
```

产生：

```text
didEnterCodexForeground
didLeaveCodexForeground
```

---

# 13. 任务状态定义

共有四种用户可见状态。

---

## 13.1 Running

含义：

Codex 当前仍在执行。

UI：

```text
🟡
```

黄色圆点。

例如：

```text
🟡 Sandbox
```

---

## 13.2 Waiting Decision

包括：

```text
Approval
Permission
User Input
Option Selection
```

UI：

```text
⚠
```

黄色警告标记。

必须闪烁。

例如：

```text
⚠ Sandbox
```

---

## 13.3 Completed

表示：

```text
Execution 成功完成
+
用户尚未确认查看
```

UI：

```text
🟢
```

绿色圆点。

例如：

```text
🟢 Sandbox
```

---

## 13.4 Failed

表示本轮 Execution 最终失败。

UI：

```text
🔴
```

例如：

```text
🔴 Sandbox
```

---

# 14. 状态颜色约定

| 状态 | 表现 |
|---|---|
| Running | 黄色圆点 |
| Waiting Decision | 黄色 ⚠ 闪烁 |
| Completed | 绿色圆点 |
| Failed | 红色圆点 |

不显示普通 Idle Thread。

---

# 15. Failed 定义

不能把：

```text
shell command exit != 0
```

直接判为 Failed。

Codex 正常工作过程可能包括：

```text
test fail
→ fix
→ test
→ success
```

只有最终：

```text
Turn Failed
System Error
Unrecoverable Error
```

才能标红。

---

# 16. MonitoredExecution 数据模型

```text
MonitoredExecution {
    threadId
    turnId

    title
    cwd
    repository

    state

    startedAt
    updatedAt

    acknowledged

    decisionRequest?
}
```

---

# 17. 任务名称

显示名称优先级：

```text
Codex Task / Thread Title
↓
Git Repository Name
↓
cwd basename
↓
Task N
```

Touch Bar 建议显示：

```text
8 ~ 12 chars
```

例如：

```text
AgentSand…
```

---

# 18. 任务排序

任务排序优先级：

```text
Waiting Decision
>
Failed
>
Completed
>
Running
```

同状态：

```text
最近发生状态变化
优先
```

---

# 19. Completed / Failed 确认机制

例如：

```text
🟢 Sandbox
```

用户点击。

系统执行：

```text
acknowledged = true
```

可同时激活对应 Codex Task。

之后：

```text
terminal && acknowledged
```

则：

```text
removeFromMonitor()
```

---

# 20. 新 Execution 再次出现

Sandbox：

```text
Turn 17
Completed
Acknowledged
```

从 Touch Bar 消失。

随后：

```text
Turn 18
Running
```

则必须重新进入监控。

不能因为：

```text
Sandbox Thread 已经确认过
```

而忽略新 Turn。

---

# 21. 多任务 Dashboard

例如：

```text
Sandbox     Running
UMDK        Running
openEuler   Decision
Test        Completed
```

Touch Bar：

```text
🟡 Sand │ 🟡 UMDK │ ⚠ OE │ 🟢 Test │ 61ms │7D72%│◉
```

---

# 22. 任务数量过多

默认显示：

```text
最多 4 个
```

超过：

```text
+N
```

例如：

```text
⚠ Sand │ 🟡 UMDK │ 🔴 Test │ 🟢 OE │ +3 │ 61ms │7D72%│◉
```

点击：

```text
+3
```

进入任务列表分页。

---

# 23. Decision Manager

模块：

```text
DecisionManager
```

处理：

```text
Approval
Permission
Option
Free Text Input
```

---

# 24. Decision 数据模型

```text
DecisionRequest {
    requestId

    threadId
    turnId

    type

    prompt
    options[]

    createdAt
}
```

类型：

```text
approval
permission
option
text
```

---

# 25. 单 Decision

如果：

```text
decisionCount == 1
```

则自动进入对应 Decision View。

例如：

```text
Sandbox │ ⚠ Apply patch? │ Apply │ Reject │ 61ms │7D72%│◉
```

最左侧必须显示任务名称。

---

# 26. 多 Decision

如果：

```text
decisionCount > 1
```

不得自动进入任何任务。

显示：

```text
⚠ 3 │ Sandbox │ UMDK │ OE │ 61ms │7D72%│◉
```

用户选择：

```text
Sandbox
```

进入该任务 Decision。

---

# 27. Decision 完成

例如：

```text
Sandbox │ Allow │ Session │ Deny
```

用户选择：

```text
Allow
```

响应必须精确发送给：

```text
threadId
turnId
requestId
```

完成后：

如果没有其他 Decision：

返回 Dashboard。

如果还有多个：

```text
⚠ 2 │ UMDK │ OE
```

不得自动跳转至下一个。

---

# 28. Approval UI

例如：

```text
Sandbox │ ⚠ Execute sudo? │ Once │ Session │ Reject
```

一点击必须只代表一个明确动作。

禁止：

```text
Approve All
```

---

# 29. Structured Option UI

Codex：

```text
Which database?
```

选项：

```text
SQLite
PostgreSQL
MySQL
```

显示：

```text
Sandbox │ SQLite │ PostgreSQL │ MySQL │ 61ms │7D72%│◉
```

---

# 30. Options 过多

最多直接显示：

```text
3
```

例如：

```text
SQLite │ PostgreSQL │ MySQL │ More…
```

点击：

```text
More…
```

进入扩展选择菜单。

---

# 31. Touch Bar Text Input

如果 Codex 需要自由文本：

```text
Enter branch name:
```

不要求用户回到 Codex。

进入：

```text
Text Input Mode
```

例如：

```text
Sandbox │ ⌨ feature/runtime█ │ Cancel │ Send │ 61ms │7D72%│◉
```

---

# 32. Text Input 核心目标

用户可以：

```text
保持 Safari / IDE / 文档在前台
```

同时：

```text
通过实体键盘
```

直接输入 Codex 请求内容。

当前输入内容必须实时显示在 Touch Bar。

---

# 33. Input Session

```text
InputSession {
    threadId
    turnId
    requestId

    taskName
    prompt

    text

    secure

    state
}
```

状态：

```text
Presented
↓
Capturing
↓
Send / Cancel
```

---

# 34. 自动展示与键盘接管分离

只有一个 Text Input Request 时：

Touch Bar 可以自动切换为输入界面。

但是：

```text
禁止自动接管键盘
```

否则用户正在浏览器打字时可能误输入 Codex。

必须：

```text
用户点击 Touch Bar 输入框
```

之后：

```text
Keyboard Capture = ON
```

---

# 35. Keyboard Capture 标识

捕获键盘后：

必须明确显示：

```text
⌨
```

例如：

```text
Sandbox │ ⌨ feature/runtime█ │ Send
```

让用户明确知道键盘现在输入到 Codex。

---

# 36. Keyboard Capture 行为

Capture ON：

```text
键盘字符 → InputSession
```

当前前台应用不应同时收到字符。

Send / Cancel 后：

```text
Keyboard Capture = OFF
```

键盘立即归还前台应用。

---

# 37. Input 快捷键

Capture 状态：

```text
Enter
→ Send

Esc
→ Cancel

Backspace
→ Delete

Command + A
→ Select All

Command + C
→ Copy

Command + V
→ Paste

Command + X
→ Cut
```

---

# 38. 中文输入

正式版本必须支持：

```text
中文 IME
英文
符号
数字
Emoji
```

不能只通过原始 keyCode 拼字符。

需要依赖：

```text
macOS 标准文本输入体系
```

推荐：

```text
Hidden Non-Activating Input Host
+
NSTextInputClient / NSTextField
```

---

# 39. 输入内容显示

输入较短：

```text
feature-agent
```

完整显示。

输入较长：

```text
implement-agent-runtime-resource-isolation
```

自动横向滚动：

```text
...runtime-resource-isolation█
```

始终保证 cursor 附近内容可见。

---

# 40. Sensitive Input

如果请求被明确标识为：

```text
password
token
secret
credential
```

Touch Bar 显示：

```text
••••••••
```

InputBuffer：

```text
不得写日志
不得进入 analytics
不得进入 crash metadata
```

Send / Cancel 后立即清空。

---

# 41. Options + Other

例如：

```text
SQLite
PostgreSQL
MySQL
Other
```

Touch Bar：

```text
SQLite │ PostgreSQL │ MySQL │ Other…
```

点击 Other：

进入：

```text
Text Input Mode
```

---

# 42. 网络质量

Persistent Area 中永久显示：

```text
OpenAI Network Health
```

格式：

```text
61ms
```

不直接显示：

```text
VPN ON
```

因为用户真正关心的是：

```text
OpenAI 是否可访问
+
当前访问质量
```

---

# 43. VPN / 代理环境

产品必须兼容：

```text
Clash
Clash Verge
Surge
TUN
System Proxy
传统 VPN
```

不得假定：

```text
存在 utun
=
网络正常
```

也不得假定：

```text
不存在 VPN Interface
=
OpenAI 不可访问
```

---

# 44. Network Monitor

模块：

```text
NetworkMonitor
```

流程：

```text
ping chatgpt.com
        │
        ├── success
        │    ↓
        │   RTT
        │
        └── failure
             ↓
        TCP/HTTPS Fallback
```

---

# 45. Network UI

建议阈值：

```text
<100ms
绿色

100~250ms
黄色

>250ms
红色

Unavailable
红色 OFF
```

示例：

```text
🟢 61ms
🟡 173ms
🔴 432ms
🔴 OFF
```

---

# 46. Network Refresh

正常：

```text
10 seconds
```

断网后：

```text
3 seconds
```

连续恢复稳定后：

恢复：

```text
10 seconds
```

---

# 47. 周额度

只显示：

```text
Weekly / 7D
```

不显示：

```text
5H
```

UI：

```text
7D72%
```

含义：

```text
Remaining Percentage
```

---

# 48. Quota 状态

数据模型：

```text
QuotaStatus {
    remainingPercent
    resetAt
    updatedAt
    stale
}
```

显示：

```text
7D72%
```

---

# 49. Quota 生命周期

Quota Monitor 必须：

```text
独立于 Codex Desktop
```

即使：

```text
Codex.app 未启动
```

Persistent Area 仍应尽可能展示：

```text
7D72%
```

---

# 50. Quota 获取失败

当前没有有效数据：

```text
7D--
```

已有缓存但当前刷新失败：

继续显示最后结果。

例如：

```text
7D72%
```

但 UI 弱化提示：

```text
stale
```

---

# 51. Quota 颜色

建议：

```text
>30%
normal

10%~30%
yellow

<10%
red
```

不闪烁。

---

# 52. Codex Launcher

Persistent Area 最右侧始终存在：

```text
Codex Logo
```

代表：

```text
Open Codex
```

---

# 53. Launcher 行为

用户点击：

```text
Codex Logo
```

系统判断：

```text
Codex Desktop 是否已运行
```

如果已运行：

```text
Activate Codex
```

如果未运行：

```text
Launch Codex
→
Activate Codex
```

---

# 54. Launcher 不依赖 Codex 状态

图标无论：

```text
Codex Running
Codex Not Running
Codex Has Tasks
Codex No Tasks
```

都保持相同。

避免用户记忆：

```text
灰色什么意思
亮色什么意思
```

它只承担：

> 打开 Codex

---

# 55. Codex 未安装

点击：

```text
Codex Logo
```

若找不到 Codex：

显示：

```text
Codex Not Installed
```

第一阶段不自动安装。

---

# 56. Dynamic Area 与 Persistent Area 关系

无论动态区域处于：

```text
App Native Controls
Task Dashboard
Decision Selector
Approval
Text Input
Task Detail
```

右侧永远：

```text
Network │ Quota │ Codex
```

---

# 57. 示例：普通应用

```text
Safari Controls │ 61ms │7D72%│◉
```

---

# 58. 示例：后台 Codex

```text
Safari Controls │ 🟡 Sand │ 🟡 UMDK │ 61ms │7D72%│◉
```

---

# 59. 示例：单 Decision

```text
UMDK │ ⚠ Apply? │ Apply │ Reject │ 61ms │7D72%│◉
```

---

# 60. 示例：多 Decision

```text
⚠3 │ Sand │ UMDK │ OE │ 61ms │7D72%│◉
```

---

# 61. 示例：自由输入

```text
Sandbox │ ⌨ feature/runtime█ │ Cancel │ Send │ 61ms │7D72%│◉
```

---

# 62. Task Detail

点击 Running Task：

```text
🟡 Sandbox
```

进入：

```text
← │ Sandbox │ Running │ pytest │ 2m31s │ Open
```

第一版必须支持：

```text
Open
```

点击后打开 Codex 对应任务。

---

# 63. Stop Task

MVP 可不支持。

后续版本可以增加：

```text
Stop
```

需要显式确认，避免误杀 Agent。

---

# 64. Touch Bar 页面模型

系统主要包含：

```text
Dashboard
Decision Selector
Decision View
Text Input View
Task Detail
```

Persistent Area 不属于页面切换体系。

它永久存在。

---

# 65. UI 优先级

动态 UI 优先级：

```text
Active Text Input
>
Single Decision
>
Multiple Decision Selector
>
Task Dashboard
>
Native App UI
```

---

# 66. Decision 闪烁

只有：

```text
Waiting Decision
```

允许闪烁。

建议：

```text
0.8~1.2 second
```

以下禁止闪烁：

```text
Running
Completed
Failed
Network
Quota
```

---

# 67. Task Monitor 架构

```text
Codex App Server
       │
       ▼
CodexEventAdapter
       │
       ▼
ExecutionManager
       │
       ├── MonitoredExecutionSet
       │
       └── Execution State
```

---

# 68. Decision 架构

```text
Codex Event
   │
   ▼
DecisionManager
   │
   ├── Approval
   ├── Permission
   ├── Options
   └── Text Input
```

---

# 69. Touch Bar 架构

```text
TouchBarController
│
├── DynamicAreaController
│
└── PersistentTrayController
```

---

# 70. Persistent Tray 架构

```text
PersistentTrayController
│
├── NetworkMonitor
├── QuotaMonitor
└── CodexLauncher
```

---

# 71. Text Input 架构

```text
TextInputController
│
├── InputSession
├── KeyboardCapture
├── IME Host
└── TouchBar Input Renderer
```

---

# 72. Application Architecture

```text
CodexTouchBarMonitor.app
│
├── AppLifecycle
├── TouchBarPrivateBridge
│
├── TouchBarController
│   ├── DynamicAreaController
│   └── PersistentTrayController
│
├── ApplicationMonitor
│
├── CodexConnectionManager
├── CodexEventAdapter
│
├── ExecutionManager
├── DecisionManager
├── TextInputController
│
├── NetworkMonitor
├── QuotaMonitor
│
├── CodexLauncher
└── SettingsManager
```

---

# 73. Codex Connection Manager

需要承担：

```text
连接 Codex App Server
重新连接
同步状态
接收事件
发送响应
```

连接断开时：

不能把所有任务直接标：

```text
Failed
```

而应进入：

```text
Unknown / Frozen
```

状态。

---

# 74. Codex Server Offline

例如：

```text
⚪ Sand │ ⚪ UMDK │ Codex Offline │ 61ms │7D72%│◉
```

连接恢复：

重新同步所有仍活动的 Execution。

---

# 75. Event Driven

任务状态必须优先使用：

```text
Event Driven
```

禁止高频轮询 Codex。

主要事件：

```text
Turn Started
Turn Completed
Turn Failed
Approval Requested
User Input Requested
Decision Resolved
```

---

# 76. Snapshot

在：

```text
用户离开 Codex
```

时：

执行一次：

```text
discoverActiveExecutions()
```

之后全部通过实时事件维护状态。

---

# 77. 多 Codex Execution

必须支持至少：

```text
10 个并发 Active Execution
```

Touch Bar 本身只显示前若干任务。

内部不得只维护：

```text
currentThread
```

---

# 78. 多 Codex Instance

如果未来存在多个 Codex App Server / Codex CLI Instance：

架构必须允许：

```text
appServerId
+
threadId
+
turnId
```

共同定位 Execution。

MVP 可以先支持 Desktop 主实例，但数据模型不得阻断多实例扩展。

---

# 79. Settings

配置：

```text
maxVisibleTasks
networkCheckInterval
autoShowSingleDecision
showNetwork
showWeeklyQuota
launchAtLogin
notificationDelay
```

---

# 80. Launch at Login

默认建议：

```text
ON
```

因为 Persistent Area 属于系统级常驻能力。

---

# 81. 应用本身

后台应用建议使用：

```text
LSUIElement
```

平时不显示 Dock 图标。

设置入口可以通过：

```text
Menu Bar
```

或者 Codex Tray 长按进入。

---

# 82. Notifications

## Decision

等待超过：

```text
30 seconds
```

仍未处理：

可发送 macOS Notification。

默认：

```text
ON
```

---

## Failed

Failed：

默认允许通知。

---

## Completed

Completed 通知：

默认关闭。

Touch Bar 绿色提示即可。

---

# 83. Privacy

不得收集：

```text
Prompt 正文
用户输入正文
代码内容
Approval 内容
文件内容
```

默认不使用远程 Analytics。

---

# 84. Secret Handling

敏感输入：

只存在于内存。

不得持久化。

Send / Cancel：

立即：

```text
zero / release InputBuffer
```

---

# 85. 性能目标

常驻工具目标：

```text
Idle CPU < 1%
```

内存目标：

```text
<100MB
```

理想：

```text
30~60MB
```

---

# 86. Network 开销

正常状态：

```text
Network Monitor:
10s

Quota Poll fallback:
60s+
```

Codex 状态：

```text
Event Driven
```

---

# 87. 技术栈

推荐：

```text
Swift
AppKit
SwiftUI
NSTouchBar
NSWorkspace
Network.framework
URLSession
Codex App Server JSON-RPC
```

---

# 88. Private API

Persistent Control Strip 允许使用：

```text
Apple Touch Bar Private API
```

所有 Private API：

必须封装：

```text
TouchBarPrivateBridge
```

---

# 89. Private API 降级策略

如果未来 macOS 更新导致：

```text
Control Strip Private API
```

失效：

应用仍应可以：

```text
启动
连接 Codex
运行 Network Monitor
运行 Quota Monitor
```

只是：

```text
Persistent Touch Bar
```

功能降级。

不得整个应用崩溃。

---

# 90. macOS 兼容风险

由于 Touch Bar 已不再出现在新款 Mac 产品线上：

项目明确定位为：

```text
Touch Bar MacBook Pro 专用增强工具
```

不以长期 Apple 官方 API 稳定性为前提。

---

# 91. 分发方式

不以 Mac App Store 为目标。

推荐：

```text
GitHub Releases
Homebrew Cask
```

后续：

```text
Developer ID Signing
Notarization
```

---

# 92. MVP v0.1

实现：

```text
Persistent Tray
Network
Weekly Quota
Codex Launcher
```

验证：

```text
跨应用永久显示
+
不破坏原应用 Touch Bar
```

这是第一阶段最重要技术验证。

---

# 93. MVP v0.2

增加：

```text
ApplicationMonitor
Active Execution Discovery
Task Dashboard
Running
Completed
Failed
Acknowledgement
```

---

# 94. MVP v0.3

增加：

```text
Approval
Single Decision
Multi Decision Selector
Decision Response
```

---

# 95. MVP v0.4

增加：

```text
Text Input
Keyboard Capture
English Input
Clipboard
```

---

# 96. Beta v0.5

增加：

```text
Chinese IME
Option + Free Text
Task Detail
Open Task
Notifications
```

---

# 97. V1.0

达到完整体验：

```text
Persistent OpenAI Network Health

Persistent Weekly Quota

Persistent Codex Launcher

Multi Codex Task Monitoring

Decision Queue

Approval

Structured Options

Touch Bar Free Text Input

Chinese IME

Execution Lifecycle

Completed / Failed Acknowledgement
```

---

# 98. V1.1 后续方向

可以继续增加：

```text
Stop Task
Pause Task

Agent Duration

Current Tool Display

Current Command Display

Task Progress

Sub-Agent Count

Context Usage

Sound / Haptic Feedback

Custom Themes
```

---

# 99. 明确非目标

第一版不做：

```text
完整 Codex 聊天界面

历史 Thread 浏览

代码 Diff 阅读

代码编辑

Prompt 长文本编写

Terminal Emulator

Git Client

IDE
```

这些仍属于 Codex Desktop / IDE / Terminal。

---

# 100. 最终体验定义

没有 Codex：

```text
Safari Controls                         │ 61ms │7D72%│◉
```

点击：

```text
◉
```

启动 Codex。

---

Codex 后台执行：

```text
Safari Controls │ 🟡 Sand │ 🟡 UMDK │ 58ms │7D71%│◉
```

---

Sandbox 完成：

```text
Safari Controls │ 🟢 Sand │ 🟡 UMDK │ 60ms │7D71%│◉
```

---

UMDK 请求 Approval：

```text
UMDK │ ⚠ Apply changes? │ Apply │ Reject │ 62ms │7D71%│◉
```

---

用户批准。

继续：

```text
🟢 Sand │ 🟡 UMDK │ 62ms │7D71%│◉
```

---

Sandbox 请求文本：

```text
Sandbox │ ⌨ Enter branch… │ 60ms │7D70%│◉
```

用户点击输入框。

输入：

```text
feature/agent-runtime
```

Touch Bar：

```text
Sandbox │ ⌨ feature/agent-runtime█ │ Send │ 60ms │7D70%│◉
```

Enter。

Codex 继续执行。

用户全程没有离开 Safari。

---

# 101. 产品核心价值

这个产品最终解决的是：

> **Codex 在后台工作时，我不应该为了“看看它现在怎么样”而不停回到 Codex。**

Touch Bar 应承担：

```text
Awa