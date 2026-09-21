# 参与贡献

欢迎提交可复现的问题、兼容性反馈和范围明确的 Pull Request。请先阅读 README 与对应 Release 的已知限制。

## 开发环境

- macOS 13+、Apple Silicon、支持 Swift 5.9 或更新版本的 Xcode Command Line Tools。
- 按 README 创建仅保存在本地的 `work/build-host.json`，然后运行 `bash scripts/test.sh` 与 `bash scripts/build.sh`。
- 原生 UI 检查需要图形登录会话；普通自动测试使用虚构任务，无需实体 Touch Bar。
- `--live` 额外连接本机 Codex 服务。不要使用真实任务测试审批、停止或回复操作。

## 提交修改

说明问题、修改后的行为、验证方式和仍未验证的环境。涉及任务操作时检查 host/thread/turn/request 身份隔离、重复点击和连接中断。
只修改相关文件；不要提交 `work/`、`dist/`、账号目录、运行日志或真实任务内容。
文档和外观小改无需为了凑数量增加测试；状态机、协议和任务控制应有针对性的离线验证。

## 兼容性反馈

请提供 App、macOS 和 Codex 版本，机型是否有 Touch Bar，问题涉及本机还是远端，以及脱敏后的复现步骤。
报告硬件测试时区分“实际验证”“模拟验证”和“尚未验证”。

## 许可证状态

仓库尚未选择开源许可证；源码可见不等于已授予通用复制、修改或再分发许可。计划复用或分发时，请先与维护者确认授权范围。
