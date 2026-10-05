# 贡献指南

感谢你帮助改进泊舟。提交 Issue 时请提供应用版本、macOS 版本、芯片架构、复现步骤、预期与实际行为。分享日志前删除主机地址、用户名、命令输出和其他敏感信息。

## 开发流程

1. 从 `main` 创建用途明确的分支，例如 `fix/forward-editor`。
2. 阅读 `README.md` 和 `AGENT.md`，先确认现有改动与数据隔离方式。
3. 保持修改集中，为错误行为添加必要回归，不为简单样式变更堆积测试。
4. 执行与变更相关的测试；涉及应用分发时还需 Release 构建及包校验。
5. 提交 PR，说明解决的问题、用户可见行为和实际验证结果。

源码使用四空格缩进。业务状态集中在模型中，阻塞 IO 不放主线程；错误应提供可执行的信息。公开配置和示例使用 `example.com` 或回环地址，不能包含真实凭据。

测试入口、模块说明与核心不变量详见 `AGENT.md`。Swift 测试使用可执行断言运行器；单独运行 `swift test` 不会执行这些检查。不要并发运行同一目录的 Swift 构建或集成 fixture。

## 提交规范

提交标题使用 Conventional Commits：`type(scope): subject`。`scope` 可省略，`subject` 使用简短的英文祈使句；正文说明改动动机和关键约束，不复述 diff。每个提交只包含一个可独立审查的逻辑变更。

Git author 和 committer 使用实际负责人身份，不在提交正文重复添加 `Author:`。当前维护者身份为 `Zhenxiong Tian <sancpp@qq.com>`。由 GPT-6-Astra 实质协助完成的提交，在正文后保留一个空行并添加：

```text
Co-authored-by: GPT-6-Astra <noreply@openai.com>
Signed-off-by: Zhenxiong Tian <sancpp@qq.com>
```

AI trailer 用于透明记录协作过程；该邮箱是项目约定的工具标识，不表示 AI 拥有 GitHub 账号、法律作者身份或提交责任。`Signed-off-by` 表示人类提交者接受 [Developer Certificate of Origin 1.1](https://developercertificate.org/)；它不等同于加密签名。维护者提交和发布标签还应使用已配置的 GPG 或 SSH 密钥签名，并在提交前完成适用测试。

## 可选插件兼容矩阵

在 Bash 中执行，插件只下载到项目目录：

```sh
brew install python@3.14 bash tmux
export BOZHOU_PYTHON="$(brew --prefix python@3.14)/bin/python3.14"
export BOZHOU_TEST_BASH="$(brew --prefix bash)/bin/bash"
export BOZHOU_TEST_TMUX="$(brew --prefix tmux)/bin/tmux"
git clone https://github.com/ohmyzsh/ohmyzsh.git .runtime/ohmyzsh
git -C .runtime/ohmyzsh checkout 4d4cfc287e9d887b81242c0e431b5f49f9cec5c1
git clone https://github.com/gpakosz/.tmux.git .runtime/ohmytmux
git -C .runtime/ohmytmux checkout 58a3dcc0d718ec0fa1c0d5a2fddd640a1ad7a5b7
bash Scripts/test.sh --unit
"$BOZHOU_PYTHON" Scripts/test_shells.py
```

矩阵检查 Bash 3 / 5、Zsh、Oh My Zsh 和 tmux。它使用独立 HOME、历史文件及 tmux socket；结果保存在 `.runtime/shell-matrix/`。无需修改个人 Shell 配置。

## 依赖与发布

更新子模块时固定到明确提交，同时核对许可证、`THIRD_PARTY_NOTICES.md` 和补丁适用性。不得直接编辑 `.runtime/SwiftTerm` 生成副本。

维护者发布流程：

1. 更新 `VERSION` 及相关用户文档，通过 CI 并合入 `main`。
2. 在最终提交创建 `git tag -s release/vX.Y.Z -m "泊舟 X.Y.Z"`，推送该标签。
3. Actions 再次验证并生成 Draft Release，包含 ZIP 与 SHA-256 校验和。
4. 下载并确认产物、签名状态和说明后发布草稿。当前流水线不含 Developer ID 签名或公证，不应标注为已公证。

将项目首次托管到 GitHub 后，维护者应启用 `main` 分支保护、要求 PR 和 `verify` 检查，并开启私密漏洞报告。上述仓库设置需要在 GitHub 配置。

`Docs/` 等本地调试材料只保留在开发机，不纳入提交或发行包。正式开发文档维护在根目录，保证干净克隆即可理解和构建项目。
