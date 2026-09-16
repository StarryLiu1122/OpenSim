# V4 原版运行对照与 FP 融合网关

版本：FP 网关/Bot 0.4.1，FP 协议 0.2；与桌面及仓储 0.4.2 分别版本化。原版业务源码不变，模块通过 Mono.Addins 加载。SQLite 桌面仓储是独立实现，见 [services](../services/README.md)，不会直接操作 OpenSim 的数据库。

## 1. 固定输入

| 项目 | 本轮基线 |
| --- | --- |
| 系统 | Windows 11 x64 26200；PowerShell 7.6.5 |
| 原版 | OpenSimulator 0.9.3.0；上游提交 `1f4a6dd1d3ff653ecc2748a7764106c30ac4ef9d`，来源及 Git 树见 [reference.lock.json](opensim/reference.lock.json) |
| .NET | SDK 8.0.424，目标 net8.0；实测运行时 8.0.30 |
| 原版物理/脚本 | BulletSim、YEngine；256×256 m 独立平地单区域 |
| Bot 客户端 | OpenSim 的 libopenmetaverse 分支，提交及补丁见 [client.lock.json](opensim/client.lock.json) |
| 现代对照 | Godot 4.5.1 标准版、Jolt、GDScript |

原版与插件工程引用固定原版程序集，不引入网关 NuGet 依赖。Bot 的 TexturePipeline 使用合作停止补丁，替换 .NET 8 不支持的 Thread.Abort；自动外观烘焙关闭，语音、服装/外观管理、复杂动画不在 Bot 验收范围。对崩溃遗留在线记录，仅在固定原版返回明确的 already-logged-in 响应时重试登录一次；不放宽原版重复在线和认证检查。

## 2. 从新目录建立实例

仓库需要保留原版初始导入提交的完整 Git 历史。所有命令在仓库根目录的 **PowerShell 7** 中执行。实例和报告使用新目录；端口避免与现有服务冲突。

```powershell
$reference = Join-Path $PWD ('integration\runtime\reference ' + [guid]::NewGuid().ToString('N'))
.\integration\opensim\Build-Reference.ps1 -OutputDirectory $reference
$source = Join-Path $reference 'source'
.\integration\opensim\Initialize-Reference.ps1 -SourceDirectory $source -Port 19230 -EnableFusion
$clientSource = Join-Path $PWD 'integration\runtime\client-source'
git clone https://github.com/opensim/libopenmetaverse.git $clientSource
$clientBuild = Join-Path $PWD ('integration\runtime\client-build ' + [guid]::NewGuid().ToString('N'))
.\integration\opensim\Build-BotClient.ps1 -ClientRepository $clientSource -Destination $clientBuild
.\integration\opensim\Install-FusionGateway.ps1 -SourceDirectory $source -ClientBuildDirectory $clientBuild
```

构建脚本验证固定 Git 树、生成工程并写报告。客户端脚本在精确导出根目录应用补丁，检查补丁后置条件并记录全部依赖摘要；安装器验证该报告，不能用未修复的旧客户端 DLL 代替。上游库仍有未使用功能的编译警告，插件和 Bot 工程本轮为 0 警告/0 错误。

初始化生成独立区域、账户、密码及测试令牌，保存为 `source/reference-private.json`，不得上传。网关安装增加 observer 与 secondary 测试主体，字段和能力见 [FP 0.2 合同](../docs/contracts/fp-v02.md)。HTTP 原版共享监听器保留上游绑定行为，Fusion 额外检查真实 loopback 对端；该配置用于本机测试，不是公网部署。

原版每次启动执行 `terrain fill 0`，不要将本例用于正式地形存档。测试账户、数据库、日志和引擎均留在运行目录；原版日志可包含会话标识，不能整体提交。

## 3. 日常闭环验证

终端 A 启动实例，等待 `LOGINS ENABLED`：

```powershell
.\integration\opensim\Start-Reference.ps1 -SourceDirectory $source
```

终端 B 使用 Python 3 标准库模拟平台，操作真实原版区域；测试目录必须新建，区域必须无对象和 Avatar：

```powershell
python .\integration\opensim\Test-Fusion.py "$source\reference-private.json" "$reference\experiment"
.\integration\contracts\Test-FpContracts.ps1 -ExperimentDirectory "$reference\experiment" -Report "$reference\schema.json"
```

闭环执行能力发现、初态订阅、实验开始、Bot 创建、移动/转向/观察、门交互、静态修改、事件读取、Bot 退出及导出，并验证重复、乱序、越权、遮挡、取消与碰墙超时。结果保存到初态、events、commands-and-receipts、telemetry 和 manifest 文件。没有真实模型、API Key 或外部消息总线参与。

结束在终端 A 输入 `shutdown`。重新运行同一测试时，建议新建实例；`--clean-previous` 仅允许清理该测试认识的单部件名称和认证所有者，遇到其他对象会拒绝，不能用于清理用户场景。

## 4. 自动冷重启及故障验收

停止专用实例之后运行：

```powershell
python .\integration\opensim\Test-FusionRecovery.py $source "$reference\recovery"
```

脚本独占启动/停止这个实例，检查端口原本空闲；不会连接其他已运行服务器。它执行完整闭环、事件缓冲区溢出、新快照重订阅、三轮登录转向退出、受控 Bot 进程终止、服务器与其子进程终止、持久回执、结果未知、显式重连及过期会话。临时使用支持的 32 条事件缓冲区，最后恢复配置。日志保持本地，发布仅使用筛选过的结构化报告。

不支持在线替换 DLL；安装新模块前正常停止实例。所谓模块重启验收为冷重启，检查新世代、单一端点和无重复事件；不是任意插件热卸载保证。移动失败/取消可能已经产生部分物理位移，不能当作事务回滚。

## 5. 原版两部件与现代数据对照

另建空实例。终端 A 运行原版，终端 B 启动独立协议 Bot 以满足原版复制权限；终端 C 运行 Linkset 测试。

```powershell
.\integration\opensim\Start-ReferenceBot.ps1 -SourceDirectory $source -Report "$reference\bot.json" -HoldSeconds 600
.\integration\opensim\Test-Linkset.ps1 -PrivateConfig "$source\reference-private.json" -EvidenceDirectory "$reference\linksets" -Phase Create
```

完成 Create 后让 Bot 退出，原版 `shutdown`，重新启动并依次执行以下阶段，每两个恢复阶段之间再次正常重启：

```powershell
.\integration\opensim\Test-Linkset.ps1 -PrivateConfig "$source\reference-private.json" -EvidenceDirectory "$reference\linksets" -Phase RestartLinked
.\integration\opensim\Test-Linkset.ps1 -PrivateConfig "$source\reference-private.json" -EvidenceDirectory "$reference\linksets" -Phase RestartUnlinked
.\prototype\tools\Test-ReferenceLinkset.ps1 -Godot $godot -OutputDirectory "$reference\modern"
.\integration\opensim\Compare-Linksets.ps1 -OriginalEvidence "$reference\linksets" -ModernEvidence "$reference\modern" -Report "$reference\comparison.json"
```

结构化结果决定根身份、链接顺序、局部/世界变换和保存恢复结论，Viewer 图像只能补充显示证据。固定版本 Firestorm OS 7.2.3.80036 使用 `--grid http://127.0.0.1:<port>`；本轮发现 `--loginuri` 不会正确选择该本地网格。先核对实际网格地址，再使用该实例的专用测试账户；不要把个人账户凭据传给测试区域。Viewer 的 `--settings` 使用独立文件名，不能传开发机绝对路径作为该参数。

## 6. 范围与证据

- 原版组 UUID 等于根 UUID，现代组使用独立 UUID；统一缩放的字段表达不同，以合成世界变换比较。见 [两部件报告](../docs/comparisons/v4-reference-linkset.md)。
- FP 只承诺 [0.2 合同](../docs/contracts/fp-v02.md) 中的子集。完整地块/库存/SSO、任意脚本、导航、外部平台与高负载能力未交付。
- [Web 探测](web/README.md) 和 [真实建筑样例](../prototype/fixtures/buildings/pioneer-log-cabin/README.md) 独立验收，不能由原版或桌面测试替代。
- 本轮原生 188 项、界面 66 项及 SQLite/FP 的独立测试结果见 [V4 验收报告](../docs/comparisons/v4-completion.md)。断电、跨平台和长期稳定性需要另行验证。
