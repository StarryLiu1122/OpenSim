# V4 原版运行对照与融合适配

状态：**V4 首批实施，0.4.0-dev；尚未完成 V4.0、V4.1 或 V4.2 的整阶段验收**。Godot 桌面原型继续为 0.3.1。进度与剩余项见 [V4 执行记录](../docs/plans/v4-progress.md)。

本目录包含固定原版构建工具、独立区域模块、受控协议客户端、结构化接口样例和对照测试。原版业务源码保持不变；模块编译为 `RegionLab.Fusion.dll`，通过 Mono.Addins 的区域扩展点加载。没有将 OpenSim 的 SQLite 文件接入 Region Lab。

## 1. 已验证环境

| 项目 | 固定输入或实际环境 |
| --- | --- |
| 系统 | Windows 11 x64，构建号 26200 |
| 脚本工具 | PowerShell 7.6.5；本目录测试使用 `Test-Json`、`-SkipHttpErrorCheck`，不按 Windows PowerShell 5.1 验收 |
| 原版 | [reference.lock.json](opensim/reference.lock.json) 中的 OpenSimulator 0.9.3.0 Release 固定提交 |
| .NET | SDK 8.0.424；实际运行时 8.0.30；目标 net8.0 |
| 原版区域 | 256×256 米；BulletSim；YEngine；原版 SQLite 独立存储 |
| 对照客户端 | Godot 4.5.1 标准版，现有 Jolt 原型 |
| 协议 Bot | 固定源码 `bin/` 中的 OpenMetaverse 组件；摘要见 [运行依赖记录](../docs/comparisons/evidence/v4-reference-20260916/dependencies.json) |

构建所用程序集来自固定原版源树与该源树的编译输出，新增工程没有 NuGet 包依赖。需要完整 Git 历史以导出初始导入提交。Godot 原型的独立运行仍不依赖 .NET。

## 2. 从新目录构建与初始化

以下命令在仓库根目录的 **PowerShell 7** 中执行。目录、报告必须是新的；脚本拒绝覆盖已有配置和首次测试世界。

```powershell
$reference = Join-Path $PWD ('integration\runtime\reference ' + [guid]::NewGuid().ToString('N'))
.\integration\opensim\Build-Reference.ps1 -OutputDirectory $reference
$source = Join-Path $reference 'source'
.\integration\opensim\Initialize-Reference.ps1 -SourceDirectory $source -Port 19110 -EnableFusion
.\integration\opensim\Install-FusionModule.ps1 -SourceDirectory $source
```

`Build-Reference.ps1` 核对初始导入提交的 Git 树，导出源码，固定 SDK，生成 net8.0 工程，构建 Release 并写入 `build-report.json`。路径可以包含空格。生成目录包含原版 DLL、数据库和账户状态，全部属于运行材料，不提交。

初始化会生成独立区域 UUID、账户 UUID、账户密码和 64 字符十六进制测试令牌，写入 `source/reference-private.json` 与该实例的 `OpenSim.ini`。端口取值必须避开已有实例。区域 UDP 地址和访问 URL 使用 127.0.0.1；原版共享 HTTP 监听器保留上游绑定行为，Fusion 处理器额外检查请求的真实对端为 loopback。该配置用于本机实验，不是公网部署配置。

每次启动执行 `terrain fill 0`，这是固定平地案例配置；不要将它用于需要保存地形编辑的正式区域。库中日志可能包含原版会话标识，发布证据应按白名单摘录，不能提交整个运行目录。

## 3. 启动、Bot 与原版对照

在终端 A 启动原版，等待 `LOGINS ENABLED`：

```powershell
.\integration\opensim\Start-Reference.ps1 -SourceDirectory $source
```

在终端 B 设置相同 `$source`，启动 Bot；在 `BOT_READY` 后保持此终端运行。原版复制权限要求操作者在线。

```powershell
$botReport = Join-Path $reference 'bot.json'
.\integration\opensim\Start-ReferenceBot.ps1 -SourceDirectory $source -Report $botReport -HoldSeconds 600
```

Bot 通过原版登录协议进入区域，发送两秒向前移动和朝北转向，随后读取模块提供的区域位置、旋转。其测试验证有界移动，不是到达指定坐标的导航器。最多在线 600 秒；在终端 B 按 Enter 可退出。退出后区域必须不再包含该 Avatar。

在终端 C 执行创建与异常检查：

```powershell
$private = Join-Path $source 'reference-private.json'
$original = Join-Path $reference 'linkset-evidence'
.\integration\opensim\Test-Linkset.ps1 -PrivateConfig $private -EvidenceDirectory $original -Phase Create
```

1. 在终端 B 按 Enter，确认 Bot 报告 `logged_out=true`。
2. 在终端 A 输入 `shutdown`，等待退出。再次运行 `Start-Reference.ps1`。
3. 运行下列 `RestartLinked`，检查组合恢复并解除组合。
4. 再次 `shutdown`、启动，运行 `RestartUnlinked`。

```powershell
.\integration\opensim\Test-Linkset.ps1 -PrivateConfig $private -EvidenceDirectory $original -Phase RestartLinked
# 原版再次正常关闭并启动后执行：
.\integration\opensim\Test-Linkset.ps1 -PrivateConfig $private -EvidenceDirectory $original -Phase RestartUnlinked
.\integration\opensim\Test-Protocol.ps1 -PrivateConfig $private -Report (Join-Path $reference 'protocol.json')
.\integration\contracts\Test-Contracts.ps1 -Report (Join-Path $reference 'contracts.json')
```

`Create` 必须从空区域开始；不能在失败后盲目重复，尤其 `result_unknown` 可能已产生副作用。保留失败报告，检查区域实际状态后，在新的隔离实例复现。正式执行时不修改或删除用户世界。

## 4. Godot 对照及原型回归

```powershell
$godot = 'C:\path\to\Godot_v4.5.1-stable_win64_console.exe'
$modern = Join-Path $reference 'modern comparison'
.\prototype\tools\Test-ReferenceLinkset.ps1 -Godot $godot -OutputDirectory $modern
.\integration\opensim\Compare-Linksets.ps1 -OriginalEvidence $original -ModernEvidence $modern -Report (Join-Path $reference 'comparison.json')
.\prototype\tools\Test-RegionLab.ps1 -Godot $godot
```

新增 Godot 脚本在三个独立引擎进程中写入、恢复组合、解除并再次恢复。操作均经过 WorldService。比较脚本按测试部件名称与世界位置配对，验证世界位置、四元数和尺寸；不同组 ID 策略由独立断言和对照文档解释。

已有回归包含 188 项原生检查、两类跨进程恢复与三组离线批处理。本次未修改界面；66 项视觉检查沿用 V3.1 历史记录，不计为本轮重跑结果。

## 5. 当前限制与故障处理

- **Bot 客户端库**：退出时 OpenMetaverse.TexturePipeline 会调用 .NET 8 不支持的 `Thread.Abort`，在异步回调中记录异常。本次区域确认 Avatar 已离场，测试进程正常退出；这不满足长期运行 Bot 的稳定性要求。V4.1 应固定兼容修复版客户端库并执行反复登录、断线、超时与清理测试。未修改上游二进制，也未屏蔽该日志。
- **接口范围**：实验端点 `/fusion/v0/...` 提供所有者对象、所有者 Avatar 观察与静态两部件操作。完整增量、事件订阅、外部平台、SSO、导航、取消与数据库事务尚未交付，详见 [接口合同](../docs/contracts/fp-reference-v0.md)。
- **权限范围**：本机令牌对应初始化时固定的区域操作者；请求不能指定主体。当前不是完整 Viewer 权限语义的替代，跨归属对象、地块细粒度权限与多个操作者仍须补充运行测试。
- **环境错误**：受限执行环境可能阻止原版 `Util.Glob` 枚举父目录，或阻止 Godot 读取系统证书库。应记录权限错误并在允许访问的本机测试环境运行，不能把失败输出计为通过。所有 Godot 自动化命令使用独立日志路径。
- **持久化范围**：`Backup` 只报告请求原版备份，最终以正常退出后的跨进程恢复判断。当前证据不包含进程中断、断电或磁盘故障恢复。

## 6. 结果

实际报告、版本与语义差异见 [两部件运行对照](../docs/comparisons/v4-reference-linkset.md)。本目录各脚本及合同均随开发分支提交；运行程序集、账户密码、令牌、数据库与缓存不进入 Git。
