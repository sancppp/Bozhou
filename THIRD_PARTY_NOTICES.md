# 第三方组件

## SwiftTerm

- 上游：https://github.com/migueldeicaza/SwiftTerm
- 版本：`v1.13.0`
- 固定提交：`8e7a1e154f470e19c709a00a8768df348ba5fc43`
- 用途：原生终端仿真、PTY、键盘与渲染。
- 许可证：MIT，完整文本见 `Vendor/SwiftTerm/LICENSE`；亦包含于 `.app/Contents/Resources/SwiftTerm-LICENSE.txt`。
- 管理：`Vendor/SwiftTerm` 为固定提交的 Git 子模块，不直接修改上游源码。
- 本地补丁：`Patches/swiftterm-app-resources.patch` 为 Metal 资源增加标准 `.app` Resources 查找路径，并开放终端焦点回调用于分屏快捷键路由；构建时只应用于 `.runtime/SwiftTerm` 副本。根 `Package.swift` 直接编译副本的库源码，不引入上游演示和 benchmark 依赖。

## bash-preexec

- 上游：https://github.com/rcaloras/bash-preexec
- 固定提交：`5ae4758c36e8391fb3932e6ae68c283489fc813d`
- 用途：兼容 Bash 原有 DEBUG / PROMPT_COMMAND、维护 preexec/precmd 和状态传递。
- 管理：`Vendor/bash-preexec` Git 子模块，构建时复制原始脚本为资源。
- 许可证：MIT，见 `Vendor/bash-preexec/LICENSE.md`；随包提供 `bash-preexec-LICENSE.md`。

## 系统组件

SwiftUI、AppKit、Foundation、UserNotifications 等系统能力由 macOS 提供。字体使用 macOS 已安装字体。SQLite 链接系统库；OpenSSH、ssh-keygen、nc 作为系统可执行程序调用，不在安装包内重新分发。本地终端使用 `/bin/zsh`，加载用户已有 Oh My Zsh，不在应用内分发插件。

## 仅测试依赖

AsyncSSH `2.21.1`（https://github.com/ronf/asyncssh，EPL-2.0 / GPL-2.0-or-later）及其依赖仅安装在项目 `.runtime/venv` 中，用作隔离 SSH / SFTP 服务端，不包含在应用或源码提交中。安装器保留各包自带的许可证元数据。

插件兼容矩阵使用项目内的 [Oh My Zsh](https://github.com/ohmyzsh/ohmyzsh)（MIT，`4d4cfc287e9d887b81242c0e431b5f49f9cec5c1`）和 [Oh My Tmux](https://github.com/gpakosz/.tmux)（MIT / WTFPL，`58a3dcc0d718ec0fa1c0d5a2fddd640a1ad7a5b7`），保留上游许可证，不随应用分发。Bash、tmux 及测试 Python 通过 Homebrew 提供，不包含在 `.app` 中。

## 图标与参考

泊舟图标由 `Scripts/generate_icon.swift` 使用 AppKit/CoreGraphics 绘制；界面使用系统 SF Symbols，不嵌入第三方产品图片、品牌或图标。
