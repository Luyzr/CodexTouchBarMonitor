# V1.0 需求完成对照

> 历史版本记录。后续规划项已在 [V1.1 交付记录](REQUIREMENTS-1.1.0.md) 中实现并注明能力边界。

基线：已确认 PRD v1.0 + TDD v1.0；保留后续用户确认的 48×30pt 双行状态按钮。
本轮继续完成全部 V1.0 实现；用户已明确允许测试不依赖实体 Touch Bar。
“实现完成”与“在某个真实系统环境验收”分开记录。下面没有把环境相关检查伪装成已验证。

| PRD / TDD | 实现 | 自动验证或证据 |
|---|---|---|
| Persistent 区域、独立生命周期、启动器；M1 | 双行网络/额度/图标常驻，启动或激活 Codex，无安装时提示 | 构建、网络/额度核心测试、真实启动冒烟；原有双行布局保留 |
| 私有 API 封装与降级；M1/M6 | bridge 唯一私有调用入口；失败不影响服务；退出移除；唤醒/ControlStrip 重启重装 | disable-private-api 全流程；恢复路径完成，未重启用户系统服务来测试 |
| 网络、代理、刷新；§42–46 | ICMP + 系统代理 HTTPS fallback；断网 3s、连续恢复后可配置正常间隔 | RTT/颜色/恢复节奏断言；真实 probe；不以 VPN 接口推断可用性 |
| 周额度；§47–51 | 只认 10080 分钟 Codex bucket、通知优先、60s fallback、缓存弱化 | 缺失、边界、优先级、缓存测试；真实 daemon quota 读取 |
| 额度独立于 UI 进程；§49 | 优先直连常驻 daemon；它不可用时启动临时独立 app-server，读取后释放 | daemon 路径已实测；独立路径延续原实现，生命周期加连接代次保护 |
| App Server；M2 | 原生 Unix socket + WebSocket，stdio fallback，握手、分片、ping、mask、超时、取消 | 离线 stdio/WebSocket roundtrip 和真实 daemon 初始化；不再常驻 CLI proxy |
| 前后台与 Snapshot；§10–12、§76 | ApplicationMonitor 仅离开 Codex 时触发同步，前台隐藏普通运行监控，决策/终态仍显示 | 前后台状态断言、单次离开事件断言 |
| Discovery/恢复；M2/M6 | loaded list 分页、只订阅加载中的任务；旧监控轮次用 read/turns 分页恢复；事件优先于旧快照 | 12 任务两页发现、旧轮次第二页同步、连接代次/EOF/取消测试 |
| 任务身份与生命周期；§13–20 | server/thread/turn；确认仅移除确切轮次；确认墓碑抑制重放；新轮次重新加入 | 旧确认不删除新轮次、服务器隔离、迟到事件、断线 unknown 测试 |
| Failed 定义；§15 | 只按终态、systemError、willRetry=false 失败；命令失败不改终态 | 可重试/不可重试/系统错误测试 |
| 标题/排序/分页；§17–22 | 标题→仓库→cwd→Task N；状态优先级，同态按最近状态改变；默认4个，+N分页 | 命名、排序断言；桌面/Touch Bar 共享分页代码 |
| 决策队列；M4 | 单请求自动展示但不接管键盘；多请求分页选择；详情不被打断；处理后不自动跳到下一个 | 混合 request ID、并发隔离、单次回复、UI 无自动跳转测试 |
| 审批/权限；§28、M4 | 单次、显式 Session 二次确认、拒绝；尊重 availableDecisions；权限回送请求的子集 | wire value、scope、选择限制；模拟 RPC 回复确认；真实任务不用于审批测试 |
| 响应安全；M4 | server/thread/turn/request + connection generation；发送后禁用；15s 未确认提示，不自动重发 | 断线旧请求拒绝、精确 resolved、响应数量、未知交付状态路径 |
| 选项/Other；§29–30、§41 | 每页3个选项、More、Other 自由文本，多问题完整提交 | 8选项分页、多问题状态/提交测试 |
| 文本输入；M5 | 原生 nonactivating panel + NSTextView；用户点击才捕获；Enter/Esc/系统编辑快捷键 | marked text 不误提交、中文/Emoji、选择替换、私有测试剪贴板 roundtrip |
| 长文本；§39 | 按真实 UTF-16 选区映射组合字符，展示光标前后窗口，不再只截末尾 | 中间光标、长文本与 Emoji 组合验证 |
| 敏感输入；§40、§84 | NSSecureTextField；回调只发掩码；多问题答案内存缓冲；发送/取消/断线/切换清理 | 密码预览截图、明文不进入 draft、owned buffer 清空测试 |
| 焦点恢复；M5 | 保存原应用/key window，发送/取消恢复；用户主动切应用时取消捕获且不抢焦点 | native panel 测试；真实第三方应用/输入法候选窗未作跨应用人工验收 |
| Task Detail/Open；M6 | 轮次状态、cwd、当前活动/命令、运行时长；终态时长冻结；Codex 深链接与启动器降级 | 界面代码/状态验证；未声称所有未来 Codex 版本的路由兼容 |
| Stop（额外完成 §63 可选项） | 用户明确确认后按确切 thread/turn interrupt；等待终态事件 | 离线服务 interrupt 流程，仅停止目标轮次 |
| 闪烁；§66 | 仅 waitingDecision 0.8s 闪烁；运行/终态/网络/额度不闪烁 | 状态驱动 UI；无全局 modal 替换其他应用 Touch Bar |
| 通知；§82 | 默认开启，30s 决策延迟，按请求取消/去重；失败独立通知，完成不通知；正文不含任务内容 | 延迟取消、去重、失败独立与隐私测试；系统权限由 macOS 管理 |
| Settings/Login；§79–81 | 全部指定设置；SMAppService 注册/移除、requiresApproval 入口；安装到 Applications 首次配置 | 构建与静态检查；测试模式不改用户登录项或申请通知权限 |
| Privacy/logging；§83–84 | 不保存输入/审批内容/原始 RPC；无 analytics；测试只有虚构数据 | 敏感输入验证、日志人工检查；Swift/AppKit 临时副本不能保证全部物理清零，已如实标明 |
| 资源目标；§85–86 | 无任务状态轮询/1Hz连接循环；Unix直接连接；临时 quota fallback | 见 work/performance-1.0.0.json 的短时采样；不是长期稳定性承诺 |
| 分发；§91 | ZIP、SHA256、Cask、显式 GitHub draft release 脚本、可选 Developer ID/notary 脚本 | archive 内容/版本/hash 验证；Ruby/shell/Python 语法检查；本轮未发布 |

## 验证入口

- `scripts/test.sh --live`：核心 + 离线模拟 RPC + 原生 UI + 可选真实只读连接。
- `scripts/build.sh`：仅 build host workspace 编译、签名、打包；清除外置盘 AppleDouble 元数据。
- `scripts/prepare_release.py`：校验 ZIP 并生成 manifest / SHA256SUMS / Homebrew Cask，不联网发布。
- `scripts/profile_runtime.py`：启动独立 smoke 实例，统计它及其子进程；不停止用户 Codex。
- `--demo --disable-private-api`：完全离线桌面演示，无网络探测、真实请求或系统设置变更。

## 环境相关验收

真实 Touch Bar 物理位置/宽度、第三方原生控件共存、真实拼音候选窗口/焦点恢复、休眠与
ControlStrip 被系统重启后的表现仍属于目标环境验收。用户已允许不依赖实体硬件，以上不阻塞
实现或自动测试。不能仅凭模拟/native API 测试断言物理硬件已通过。
Developer ID 与公证需要用户 Keychain 中有效证书/配置；源码和脚本具备路径，目前产物仍为 adhoc 签名。
GitHub Release 和 Cask 已准备，未自动发布或改变仓库可见性。

## V1.1 探索项

PRD §98 明确标注“可以继续增加”，不是 V1.0 的验收项。本版额外实现了 Stop、duration 和当前活动。
Pause、任务进度、子代理数量、上下文用量、声音/触觉和主题仍属于后续产品规划，未伪造 App Server
不提供的暂停/进度能力，也没有把探索建议标成已交付功能。完整聊天、历史浏览、Diff 编辑等 §99
非目标保持不实现。

## 本次结果（2026-09-18）

- 核心 55 + 协议/状态/通知集成 28 + 原生 UI 流程 15 = **98 项断言通过**。
- `test.sh --live` 通过；真实 Unix daemon 握手和 loaded list 正常。
- 正常运行冒烟：发现并订阅 1 个真实任务，周额度与网络值正常，无私有 API 也可工作。
- 短时资源样本：监控器及其子进程总 RSS **57.58 MiB**，常驻进程 **1**，样本 CPU **0.16%**；
  采样窗口 6.07s，不能替代长期空闲/并发压力评估。
- Release 构建、严格签名校验、ZIP 内容/版本/哈希、Cask Ruby 语法、shell 脚本语法、diff whitespace 检查通过。
- `dist/CodexTouchBarMonitor-arm64.zip` SHA256：
  `1ca43dc68ce3f04fc593409058617c5073ea607bcbe3b908f45ed7610ff85851`。
- GitHub 草稿发布和 Developer ID 公证脚本已准备；本轮未调用发布脚本。
