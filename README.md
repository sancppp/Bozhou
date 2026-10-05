# 泊舟 Bozhou

**一款面向 macOS 的原生 SSH 工作台，让主机、终端和命令记录各有所归。**

泊舟使用 SwiftUI 和 AppKit 构建界面，以系统 OpenSSH 建立连接，结合 SwiftTerm 提供真实交互终端。所有配置保存在本机，无需注册账号或部署服务端。

本项目使用 **GPT-6-Astra** 辅助开发、代码审查与文档编写，采用 [MIT 许可证](LICENSE) 开源。

## 功能

- **主机管理**：嵌套文件夹、列表与卡片、标签、星标、搜索和排序；文件夹展开状态自动保存，切页或重启后恢复；显示实际主机名、上次登录时间及系统信息。
- **连接与认证**：密码、私钥、SSH Agent、Kerberos；最多 12 级跳板链，各级独立配置认证和端口；支持无认证 SOCKS5 / HTTP CONNECT 代理。
- **交互终端**：多会话、上下或左右分屏、原生中文输入法、本地 Zsh、自定义字体与背景色；默认浅灰底色。
- **命令与输出**：Bash / Zsh 自动记录命令、输出和退出码；快捷命令、历史搜索、交互收藏、双栏差异对比和 Markdown 导出。
- **文件与转发**：SFTP 上传、下载及远程文件管理；两台服务器间经本机内存中转文件；本地端口转发仅监听 `127.0.0.1`。
- **连接诊断**：自动重连、独立主机指纹库、原始 SSH 日志和应用事件。

## 安装

当前版本为 **1.0.0**，发布产物面向 **Apple Silicon / macOS 14 及以上**。应用运行不依赖 Python 或源码目录。

若仓库的 Releases 页面已有安装包，下载 `Bozhou-1.0.0-macOS-arm64.zip`，核对随包的 `SHA256SUMS`，解压后将 `泊舟.app` 放入「应用程序」目录。

当前构建仅使用本地 ad-hoc 签名，**尚未经过 Apple Developer ID 签名和公证**。从网络下载后可能受到 Gatekeeper 限制；确认来源后可按 macOS「系统设置 → 隐私与安全性」中的提示允许打开，或从源码构建。

从源码安装：

```sh
# 在已克隆的项目根目录执行
bash Scripts/build.sh release
bash Scripts/install.sh --no-build
open "$HOME/Applications/泊舟.app"
```

安装前请退出泊舟。默认安装到 `~/Applications`，旧应用会保留为带时间戳的备份；已有工作空间不会被覆盖。也可直接运行 `dist/泊舟.app`。

## 快速上手

1. 点击「新建主机」，填写名称、地址、端口与实际远端用户名，选择认证方式。
2. 使用私钥时，先到「密钥」导入文件；使用跳板时，先保存跳板主机，再加入目标主机的「跳板链」。
3. 点击「保存并连接」，通过可信渠道核对首次连接的服务器指纹。
4. 使用工具栏切换会话或分屏；点击左上角「泊舟」返回工作空间。
5. 在终端交互侧栏点击图钉保存命令与输出，在「交互收藏」选择两条进行对比。

主机的自定义名称与登录后采集的主机名分别展示。搜索支持名称、主机名、地址、用户名和标签。可在「登录与系统信息」查看操作系统、内核、CPU 和内存信息。

「快捷命令」只填入终端，按回车后执行。自动重连最多尝试 5 次，间隔为 2、4、8、16、30 秒；正常退出与已识别的认证、指纹错误不会自动重试。重连会创建新的远端 Shell，不会重放命令。

SFTP 从主机条目的「SFTP」入口打开。传输不覆盖同名文件；取消会关闭当前 SFTP 连接。上传中断可能留下同名部分文件，服务器间传输失败可能留下错误提示中的临时文件。

| 快捷键 | 操作 |
| --- | --- |
| `⌘N` / `⌘T` | 新建主机 / 本地终端 |
| `⌘⇧F` | 搜索主机 |
| `⌘⇧R` / `⌘⇧W` | 重连 / 关闭当前会话 |
| `⌘⇧P` | 收藏最近交互 |
| `⌘K` | 清屏并清除滚动缓冲，保留交互记录 |
| `⌘,` | 打开设置 |
| `⌘C` / `⌘V` / `Ctrl-C` | 复制 / 粘贴 / 中断 |

## 数据与隐私

工作空间默认位于 `~/Library/Application Support/Bozhou/`，包含 SQLite 数据库、`known_hosts`、日志和临时会话目录。可在设置中迁移到一个空目录，原目录会保留；迁移前需关闭终端与 SFTP 会话。

**主机密码目前以明文保存在本地数据库中。** 私钥只保存路径引用，私钥口令与验证码不会保存。请妥善管理工作空间及其备份，不要上传数据库、日志或包含敏感输出的收藏。

命令历史会保存命令与输出，可在设置中关闭或清空。应用使用独立 SSH 配置及指纹库，不读取 `~/.ssh/config`，不修改用户的 `known_hosts`。Bash / Zsh 集成在会话内加载 Hook，Zsh 使用会自动清理的临时启动文件；不安装远端 Agent。

## 构建与测试

需要 macOS、**包含 macOS 26 SDK 的 Xcode 26 或更新工具链**、Git，以及 **Python 3.10+**。新 SDK 用于编译工具栏 API，运行时通过可用性检查兼容 macOS 14。本地支持相应版本的 Command Line Tools；CI 使用 Xcode 26.6 和 Python 3.14。

克隆时包含子模块（`git clone --recurse-submodules <仓库地址>`）；构建脚本也会初始化固定提交的依赖。若系统 `python3` 版本较旧，可先设置 `BOZHOU_PYTHON`：

```sh
# 使用其他 Python 时设置为它的绝对路径
export BOZHOU_PYTHON="$(brew --prefix python@3.14)/bin/python3.14"
```

```sh
bash Scripts/build.sh release       # 编译、打包与签名校验
bash Scripts/test.sh --unit          # 核心逻辑、SQLite、Shell 和配置测试
bash Scripts/test.sh                 # 加测本地 SSH、多级跳板、SFTP 与转发
bash Scripts/test_regressions.sh     # 删除行绑定、会话关闭与取消回调回归
bash Scripts/test_native.sh          # 原生终端输入接口
"${BOZHOU_PYTHON:-python3}" Scripts/test_install.py
"${BOZHOU_PYTHON:-python3}" Scripts/verify_package.py
```

测试使用可执行 Swift 断言运行器，失败返回非零退出码；无需 XCTest。集成测试仅监听本机回环地址的随机端口，使用项目内的 AsyncSSH 环境，不启动系统 `sshd`。生成文件位于 `.build/`、`.runtime/` 和 `dist/`。

交互桌面可补充执行 `bash Scripts/test_hosts.sh`、`bash Scripts/test_hosts.sh --layout` 和 `bash Scripts/test_titlebar.sh`。插件兼容矩阵、测试隔离与贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 开发与发布

| 路径 | 职责 |
| --- | --- |
| `Sources/Bozhou/` | 界面、主机编辑、终端与 SFTP 状态管理 |
| `Sources/BozhouCore/` | 数据模型、SQLite、连接配置、Shell 集成与 SFTP 协议 |
| `Sources/BozhouAskPass/` | 独立认证及指纹确认进程 |
| `Tests/`、`Scripts/` | 测试、构建、安装及打包 |
| `Vendor/`、`Patches/` | 固定版本依赖与应用资源补丁 |
| `AGENT.md` | AI 开发会话的项目指南与约束 |

主分支为 `main`，版本由 `VERSION` 管理，发布标签为 `release/vX.Y.Z`。GitHub Actions 对 Pull Request、主分支和发布标签运行测试、构建及签名检查；发布标签通过后自动创建含 ZIP 和校验和的 **Draft Release**，由维护者核验后发布。第三方 Actions 均固定提交，并配置 Dependabot 更新。

`Docs/` 中的本地调试与验收记录、崩溃日志和历史需求文档不纳入 Git，也不打入应用。它们不是开发或构建的前置依赖。

## 当前边界

- SFTP 仅支持单文件顺序传输，不提供目录递归、断点续传或并发队列；仅能删除空目录。
- Bash / Zsh 支持自动记录；其他 Shell 使用手动快照。tmux 内部 Shell 不自动注入记录 Hook。
- 单条交互最多保存 256 KiB 输出，不能还原 Vim、top 等程序的屏幕布局。合计超过 4000 行的对比按行位置高亮。
- Intel 构建、所有 Shell 插件和所有 macOS 版本尚未逐一验证。

欢迎通过 Issue 提交可复现问题，或按 [贡献指南](CONTRIBUTING.md) 提交 Pull Request。安全问题请参阅 [SECURITY.md](SECURITY.md)；依赖与许可证详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
