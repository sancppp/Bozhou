# 插件开发

泊舟使用随应用编译的 Swift 插件模块。内置插件统一在 `Sources/Bozhou/BuiltInPlugins.swift` 注册；不从磁盘加载任意动态库。插件是同进程受信源码，接口的数据限制不构成操作系统沙箱。

## 模块与职责

| 模块 | 职责 |
| --- | --- |
| BozhouCore | 工作空间持久化、PluginSettings、受限 MetadataSubject 和元数据模型 |
| BozhouExtensions | BozhouPlugin、PluginCapability、PluginRegistry、PluginContext、MetadataCoordinator |
| BozhouNightHawk | NightHawk 描述与默认设置、本地 CLI/SSO、schema 查询、关联验证、限速、字段展开 |
| Bozhou | 组合注册、通用设置界面、能力消费和结果持久化 |

供应商的可执行文件发现、环境名、默认值、绑定字段说明和错误解释均放在插件模块。核心与通用界面不导入供应商模块，也不比较供应商 ID。

## 添加插件

1. 在 `Sources/` 添加独立模块，实现 `BozhouPlugin`。描述使用稳定且唯一的 ID，声明标题、说明、设置字段和默认值。插件默认关闭，启用状态由工作空间保存。
2. 在 `Package.swift` 添加 target，依赖 `BozhouExtensions` 和必要的模型模块，并纳入应用依赖。在 `BuiltInPlugins.register(in:)` 注册实例。原生测试根据应用链接清单自动包含新增依赖。
3. 通过 `capabilities` 返回稳定的能力实例。能力协议继承 `PluginCapability`；主机元数据可直接实现 `HostMetadataProvider`。注册后能力实例由注册表保留，只有激活中的插件会被通用 `capabilities(_:)` 发现。
4. 在插件内实现所需生命周期钩子，并为异常、取消和迟到回调增加测试。元数据能力继续复用通用设置、主机详情、空格预览和后台搜索，无需修改这些界面。

`PluginTests.swift` 包含没有元数据能力的插件和可延迟返回的元数据插件，用于验证扩展性与生命周期边界。

## 生命周期

`register()` 只安装本地能力和注册级资源，不能启动云查询。`activate(_:)` 获取当前工作空间的隔离标识和插件配置，可以使用 `context.run` 启动工作，并通过 `context.onStop` 注册清理动作。所有钩子在 MainActor 调用，须快速返回；阻塞进程或 IO 应放到后台。

禁用、执行配置变化、切换工作空间和注销会先将 `context.isActive` 置为 false，再取消任务和执行清理，最后调用 `deactivate()`。注销继续调用 `unregister()`。激活失败同样回收当前上下文；注册失败调用 `unregister()` 清理部分注册。钩子应支持重复的启停周期。

异步能力在每次等待后、发布结果前检查任务取消和 `context.isActive`。取消是协作式的，不能假定第三方 SDK 会及时响应。元数据调度器独立校验任务 token、provider ID 和 subjectKey；数据库写入还会核对当前主机的 subjectKey。

`stopWorkspace()` 停止当前工作，不卸载注册项；加载下一工作空间后调用 `configure` 激活其配置。`shutdown()` 停止并注销全部插件。注销不删除用户的持久化偏好和缓存；再次注册可复用。注册表释放时也安排资源清理。

## 设置与元数据能力

`PluginSettings.options` 保存文本选项，`selections` 保存多选项，键只在所属插件内有意义。设置控件由 `PluginDescriptor.settings` 声明生成；可执行文件和文本字段显式应用后持久化。不得在这些设置中保存密码、令牌或私钥。供应商默认值通过 `applyingDefaults` 合并，用户显式清空的值不会被默认值覆盖。

`layout` 仅供元数据能力使用；修改字段显示和排序不会重启插件。数据库沿用 `metadataExtensions` JSON 键，旧 `executable` 和 `environments` 可迁移到通用选项；旧主机绑定、缓存和字段 ID 保留。

`HostMetadataProvider` 接收 `MetadataSubject` 与插件设置，不能获取完整 Host、Store 或 AppModel。输入只有主机 ID、名称、hostname、地址和资源绑定。结果带 provider ID、subjectKey、采集时间、字段及部分失败说明。每个插件至多提供一个元数据 provider，ID 与插件一致。`acceptsCache` 定义供应商特有的缓存适用条件，队列统一执行 15 分钟有效期、串行调度与主机去重。

字段 ID 必须稳定，不能包含数组行号或某次查询的资源 ID。布局按属性 ID 保存；隐藏属性仍参与搜索，停用或注销的插件不参与搜索和预览。

## 新能力与 AI 接入

插件不必提供元数据。新增能力应定义独立、受限的协议，由对应界面或服务通过注册表消费；不把终端会话、数据库和任意回调塞入通用配置。未来 Codex 等交互能力需要明确设计用户触发、进程管理、终端读写权限和取消行为，并添加对应的消费端。当前接口不授权插件读取 SSH 凭据，也不自动执行 AI 生成的命令。

## 验证

运行 `bash Scripts/test.sh --unit` 和 `bash Scripts/test_metadata.sh`。修改主机界面或会话交互时运行对应原生回归。默认测试使用本地匿名 fixture；真实云查询须按 `AGENT.md` 的显式授权流程执行。
