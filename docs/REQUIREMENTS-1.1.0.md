# V1.1 规划项交付与边界

本版承接 V1.0，实现 PRD §98 列出的后续功能。明确非目标（完整聊天、历史浏览、代码编辑、终端等）保持不实现。

| 规划项 | 实现与验证 |
| --- | --- |
| Stop Task | 按确切 thread/turn 中断；确认后发送，操作期间禁用重复控制；模拟服务验证 |
| Pause Task | 提供 **Pause (interrupt)** 与 Continue。中断终态确认后才显示 paused；继续前检查最新轮次，显式发送继续消息开启新轮次。暂停身份与不确定状态跨重启保存；超时不重发、旧轮次拒绝继续 |
| Agent Duration | 持续显示时长，完成/失败/暂停时冻结；详情打开时才更新计时标签 |
| Current Tool / Command | 按 item ID 跟踪并发工具，完成只移除对应项，轮次结束/断线清空；不保留工具参数或输出 |
| Task Progress | turn/plan/updated；完成步骤数/总步骤数、进度条和步骤清单，修订计划替换旧计划 |
| Sub-Agent Count | collabAgentToolCall 的 receiverThreadIds / agentsStates 去重；展示本轮观察到的 active/known 和状态分组，不把未报告当零 |
| Context Usage | thread/tokenUsage/updated；最近模型调用 last.totalTokens / modelContextWindow 估算，累计 thread tokens 单独显示；未知容量不显示百分比 |
| Sound / Haptic | 两个独立设置，默认关；可独立于通知工作，沿用决策延迟/取消/去重，2 秒突发节流；设置提供预览 |
| Custom Themes | 暗色、亮色、跟随系统、自定义；自定义背景/强调色 #RRGGBB 校验、自动黑白正文对比；Touch Bar 保持可读正文和状态色 |

## 必须明确的能力限制

- 当前本机 App Server schema 提供 `turn/interrupt`、`turn/start`，不提供原生 pause/resume execution。
  本版暂停是中断式替代方案，**不是进程冻结或命令原地续跑**，也不会自动中断子代理。
- `thread/resume` 用于加载/订阅任务，不能冒充“恢复暂停执行”。继续使用 `turn/start`，不覆盖模型、审批或沙箱配置。
- 继续前读取最新轮次，并处理重复点击、RPC 拒绝、超时、断线、恢复和外部新轮次。
  服务端没有条件式 start 接口；读取和启动之间，另一客户端启动任务仍有竞态，继续确认框提示避免同时操作。
- 不确定继续请求会锁住重发，Refresh 只读核对；发现新轮次后清除暂停标记。也可以打开 Codex 核对。
- 进度为计划步骤比例，不是完成时间预测。上下文为最近调用估算，不保证等于服务端压缩后的实时精确占用。
- 仅接收订阅后的遥测事件；未报告显示 not reported，断线缓存显示 last known。子代理计数是本轮观察值，不冒充全局完整数量。
- 声音/触觉调用与去重已用注入输出验证；实际触觉依赖支持的设备。实体 Touch Bar 和硬件触觉体验未验收。

## 隐私与恢复

遥测只存内存，确认任务后释放。暂停检查点仅保存 server/thread/turn 身份与 uncertain 标记；不保存输入、命令、计划或工具输出。
继续消息为固定文本，不复用用户敏感输入。所有控制验证使用离线虚构任务；真实 daemon 只做读取。

## 验证

`bash scripts/test.sh --live`：71 核心 + 47 集成 + 21 原生 UI = **139 项断言**，另有真实 daemon 只读连接验证。
覆盖多工具完成、计划修订、用量边界、子代理去重、断线过期、暂停/继续、超时防重发、重启恢复、外部新轮次、独立反馈与四种主题。
截图在 `work/telemetry-demo.png`、`work/theme-{dark,light,system,custom}.png`。

协议参考：[OpenAI App Server](https://learn.chatgpt.com/docs/app-server)，并以本机生成的 JSON schema 核对具体字段。

## 打包结果

- 本机协议版本：codex-cli 0.154.0-alpha.6.2。
- Release 构建、adhoc 严格签名验证、ZIP 版本和内容校验通过。
- 短时冒烟样本：6.05 秒，监控器及其子进程共 57.42 MiB、0.17% CPU、1 个常驻进程；不代表长期稳定性。
- `dist/CodexTouchBarMonitor-arm64.zip` SHA256：`404e64bf1a29771bec867724b010af9b9199b81183dc1e861835bab31f1a7ab8`。
- GitHub Release 未发布；源码与交付文档一并纳入本版本 Git 提交。

Build 10：待答复图标统一使用黄色正三角/黑色感叹号矢量图；闪烁只改变明暗，不替换为圆点。Release 构建、签名、21 项原生 UI 流程及截图检查通过。
