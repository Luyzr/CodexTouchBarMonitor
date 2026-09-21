# Codex TouchBar Monitor

原生 Swift/AppKit macOS 后台 App，在 Touch Bar 显示网络时延、Codex 周剩余额度、任务状态和待回复问题。

## 安装与打开

1. 在 [Releases](https://github.com/Luyzr/CodexTouchBarMonitor/releases) 下载 ZIP，解压后把 **CodexTouchBarMonitor.app** 拖到“应用程序”。
2. 双击 App 打开状态窗口；关闭窗口后仍在后台运行。它不显示 Dock 图标，菜单栏 **CTB** 提供任务、设置和退出入口。
3. 再次从“应用程序”打开，会重新显示状态窗口。

要求 macOS 13 或更新版本、Apple Silicon。实体 Touch Bar 功能需要配备 Touch Bar 的 Mac；其他机器可使用桌面状态窗口。
当前发行包使用 ad-hoc 签名，尚未 Developer ID 签名或 Apple 公证。下载后若被 macOS 拦截，可在确认来源后使用系统“隐私与安全性”中的“仍要打开”；不需要关闭系统安全保护。私有仓库的下载需要访问权限。

## Touch Bar 操作

- 右侧常驻块：上行网络时延，下行 Codex 图标和周剩余额度。Codex 未运行时仍保留此块；不可用或过期数据有占位/失效提示。
- 单击常驻块：启动或激活 Codex。
- 双击常驻块：打开任务区；系统 **X** 返回前台应用原生控件，再次双击可以重新进入。
- 黄色圆圈表示执行中，闪烁警示三角表示有待处理问题，绿色表示完成。
- 问题中的预设选项可直接选择。自由文本回复通过 **Open Codex** 完成，Touch Bar 文本输入/中文 IME 已暂停。
- 任务区暂时替换前台应用的 Touch Bar 控件，同时保留常驻块；不切换前台应用。

## 额度账号与设置语言

在菜单栏 CTB → 设置中，可选择中文或 English；点击“额度账号…”可为 Touch Bar 单独绑定或更换账号。

- 点击“绑定 / 更换账号…”后，在 OpenAI 登录页选择账号。通过账号和周额度检查后自动切换显示。
- 此操作只改变额度来源，不退出或切换 Codex Desktop，也不改变任务监控。
- 取消、失败或关闭登录窗口时继续使用原额度来源；“恢复使用 Codex 当前账号”可解除独立绑定。
- 登录凭据保存在本 App 独立的应用支持目录中，不会复制或覆盖 Codex 的登录文件；不写入日志、仓库或发布包。
- 浏览器可能保留已有登录，请核对所选账号。账号必须提供可读取的 ChatGPT 周额度。

## 实现与边界

网络和额度独立于任务监控运行。任务使用本机 Codex Desktop IPC 事件，并以只读本地任务目录补充发现。
支持同步输入/审批请求及异步提问消息；回复按任务、当前轮次、请求和连接身份核对，未确认的回复禁止盲目重发。
使用 macOS 私有 Touch Bar 接口和 Codex Desktop 内部协议，系统或 Codex 更新可能影响兼容性。
远端主机任务发现、真实审批完整回路及长期休眠恢复尚未完成硬件验收。历史设计和测试记录见 docs，当前功能以本 README 和版本说明为准。

## 构建与测试

所有构建操作在指定的构建机器上执行，测试用 Mac 只运行已打包 App。
在构建机器克隆仓库后，创建不纳入版本控制的配置：

~~~sh
mkdir -p work
python3 - <<'CONFIG'
import json, pathlib, socket
pathlib.Path('work/build-host.json').write_text(json.dumps({
    'hostname': socket.gethostname().split('.')[0],
    'root': str(pathlib.Path.cwd().resolve())
}))
CONFIG
bash scripts/test.sh
bash scripts/build.sh
python3 scripts/prepare_release.py
~~~

构建脚本核对配置中的主机和仓库目录。源码与发行包不包含开发者机器的路径配置。
自动测试使用虚构任务；原生 UI 测试需要 macOS 图形登录会话。额外的只读服务连接检查使用 test.sh --live。
产物位于 dist：App、ZIP、SHA256SUMS 和 Homebrew Cask。sign_release.sh 可使用已有 Developer ID 和公证配置；凭据不存入仓库。
publish_release.sh 可通过已登录的 GitHub CLI 创建草稿；发布前请核对版本、标签、源码和产物。

菜单栏 Settings 可设置刷新间隔、显示开关、任务数量、通知和登录启动。高级配置可指定 Codex 可执行程序、bundle ID 和服务 socket。没有网络/额度数据时先检查 Codex 登录与网络连接。
