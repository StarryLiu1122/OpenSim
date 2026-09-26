# V5 服务工具：RegionStore / RegionHost 0.5.1

RegionStore 是 Region Lab 的 SQLite 持久化进程；离线桌面选择 `-Database` 后使用，V5 权威区域固定使用它。RegionHost 提供 Web 文件、受控 HTTPS 资产和 WebSocket 转发，世界权威位于 Godot `network/server.gd`。完整网络运行步骤见 [V5 指南](../prototype/docs/network-quickstart.md)。二者不提供 OpenSim 数据库兼容性。

V6 资产端点按每次请求查询 RegionStore 的持久会话与账户状态，再核对实时资产授权目录和文件 SHA-256。运行中签发的新账户可直接使用已获准资产；撤销会话、禁用账户或收回资产授权会影响下一次请求。隔离验收可运行 `node services/Test-AssetSessions.cjs --host=<RegionHost.exe> --store=<RegionStore.exe> --output=<全新测试目录>`。

需要 Windows x64、PowerShell 7、Godot 4.5.1。RegionStore 使用 .NET 8 Runtime，RegionHost 使用 ASP.NET Core 8 Runtime；源码构建均需要 SDK **8.0.424**。依赖锁定不变，数据库新增 schema 3 的 `network_receipts`，将网络成功回执和世界放入同一事务。默认 JSON 离线模式仍不需要 .NET。

实现与决策见 [ADR](../docs/adr/0001-v4-storage.md)、[存储合同](../docs/contracts/storage-v4.md) 和 [V4 验证报告](../docs/comparisons/v4-completion.md)。依赖通过 [packages.lock.json](RegionStore/packages.lock.json) 固定，世界校验直接调用现有 Godot/GDScript 规则。

## 1. 构建与启动

以下命令在仓库根目录执行，示例变量均为本次新目录。

```powershell
$build = Join-Path $PWD ('services\runtime\build ' + [guid]::NewGuid().ToString('N'))
.\services\Build-Store.ps1 -OutputDirectory $build
$store = Join-Path $build 'runtime\RegionStore.exe'
$godot = 'C:\path\to\Godot_v4.5.1-stable_win64_console.exe'
$data = Join-Path $PWD ('services\runtime\world ' + [guid]::NewGuid().ToString('N'))
.\prototype\Start.cmd -Godot $godot -Database $data -StoreExecutable $store
```

首次启动显示演示区域，点击“保存”才提交。关闭后使用完全相同的 `$data` 再次启动即可恢复。界面编辑、撤销重做和门灯状态仍经过 `WorldService`。保存时先验证完整候选，再执行事务；冲突或故障不会清除未保存标记。

离线构建：将上次构建的完整 NuGet 缓存带到本机，使用 `Build-Store.ps1 -PackageCache <缓存目录> -Offline -OutputDirectory <新目录>`。运行发布产物不需要 NuGet 或 SDK，但仍需 .NET 8 运行时。不要把开发缓存作为运行数据库。

## 2. 从 V3.1 迁移

保留原 JSON 存档副本，不直接修改它。格式 1、2、3 及快照封装 1 均由原生校验器读取；迁移只在目标仓储发生。

```powershell
$request = [guid]::NewGuid().ToString()
.\services\Invoke-Store.ps1 -Operation save -Root $data -StoreExecutable $store -Godot $godot `
  -InputFile 'D:\RegionLabData\v3.1-copy.json' -ExpectedCommit -1 -RequestId $request `
  -Report '.\services\runtime\first-import.json'
```

默认 RegionId 是演示区域的 `33333333-3333-4333-8333-333333333333`；其他区域必须传入其真实 ID。`ExpectedCommit=-1` 表示目标区域尚不存在，首次提交为 0。`status` 返回区域及存储提交号；它与世界内部 `revision` 是两个计数器。

若返回 `COMMIT_CONFLICT`，先备份本地未保存编辑，重新加载数据库并决定如何重做编辑。若进程退出且没有确认，保留请求文件、RequestId、ExpectedCommit 和输入字节，原样重试；不能随意换 ID 重发。修改同一请求的候选会返回 `REQUEST_REUSED`。

## 3. 备份、恢复与回滚

```powershell
.\services\Invoke-Store.ps1 -Operation backup -Root $data -StoreExecutable $store -Godot $godot `
  -OutputFile '.\services\runtime\before-upgrade.zip' -Report '.\services\runtime\backup.json'
$restored = Join-Path $PWD ('services\runtime\restored ' + [guid]::NewGuid().ToString('N'))
.\services\Invoke-Store.ps1 -Operation import -Root $restored -StoreExecutable $store -Godot $godot `
  -InputFile '.\services\runtime\before-upgrade.zip' -ExpectedCommit -1 `
  -RequestId ([guid]::NewGuid().ToString()) -Report '.\services\runtime\restore.json'
.\prototype\Start.cmd -Godot $godot -Database $restored -StoreExecutable $store
```

备份包包含一个区域的完整世界和全部登记网格资产，使用事务捕获一致状态，可单独搬移；恢复产生新存储世代。`backup` 与 `export` 相同，不复制运行中的 `.sqlite3` 文件，不依赖原 GLB 路径。多个区域需要逐一备份；首版不提供跨区域一致性。

升级步骤：停止编辑写入 → 导出并试恢复备份 → 在新目录部署新程序 → 对数据库副本执行 `init` 迁移 → 加载核对 → 将启动命令切换到新目录。schema 1/2 到 3 的迁移在事务内完成，失败回滚；未来 schema 被拒绝。不要让旧程序打开已经升级的唯一数据库。

V5 的 `receipts` 管理操作读取指定区域的持久网络成功回执；该入口仅供本机权威服务使用，没有对外公开。备份包继续导出世界与登记资产，不携带认证配置和网络回执历史；导入产生新存储世代，服务重启还会生成新网络世代。世界修订、存储提交号、网络世代和传输序列须分别处理，见 [网络合同](../docs/contracts/network-v5.md)。

回滚时停止新程序，保留失败数据以供排查，将**升级前备份**恢复到另一个目录，并使用对应旧程序和格式。回滚会舍弃备份之后的提交。V3.1 只支持 JSON：返回 V3.1 应使用升级前 JSON 副本；不要将 SQLite 或 ZIP 直接交给 V3.1。对于仍兼容世界格式 3 的 V4 发布，可用当前导出恢复工具重建独立目标，再切换客户端。

## 4. 离线运行包

在已完成构建的机器上执行：

```powershell
.\services\New-OfflinePackage.ps1 -Destination 'D:\Packages\Region Lab V5' `
  -GodotArchive 'D:\Downloads\Godot_v4.5.1-stable_win64.exe.zip' -StoreBuildDirectory $build
```

搬移整个目录，在目标机器预先安装 .NET 8 运行时与 PowerShell 7，然后从包根目录执行：

```powershell
.\services\Install-Offline.ps1
.\prototype\Start.cmd -Database 'D:\RegionLabData\new-v5-world'
```

V5 可追加 `-HostBuildDirectory <RegionHost构建目录> -WebBuildDirectory <Web导出目录>`，将已验证运行文件和完整静态客户端一并装入离线包。初始化时使用包内 `services/RegionHost/bin/Release/net8.0/RegionHost.exe`、`services/RegionStore/bin/Release/net8.0/RegionStore.exe` 及 `prototype/build/network-web/web`。这些路径是发布结果，不是要求用户安装 SDK。

安装器校验包内全部文件 SHA256，并使用固定 Godot 归档进行离线安装；网络包额外检查 ASP.NET Core 8。包不包含会话、私钥、存档或数据库；已有数据单独备份恢复。隔离目录验收未模拟全新操作系统或移除系统 .NET。

## 5. 管理与故障处理

| 结果 | 含义与处理 |
| --- | --- |
| `COMMIT_CONFLICT` | 存储提交号已变化；重新加载后处理编辑冲突 |
| `DATABASE_BUSY` | 写锁超过 3 秒仍不可用；原提交未确认成功，保留相同请求重试 |
| `WORLD_VALIDATION_FAILED` | 当前生产规则拒绝候选；检查输入，原已提交世界不变 |
| `CONTENT_*` | 资产缺失、过大或摘要不符；整次加载拒绝，使用有效备份恢复 |
| `MIGRATION_REQUIRED` / `UNSUPPORTED_DATABASE_VERSION` | 需要受支持迁移，或程序版本过旧 |
| `STORAGE_UNAVAILABLE` | 路径不可用、权限或文件 I/O 失败；检查磁盘和目标路径 |
| 没有响应文件 | 提交结果未知；原样重试，通过持久请求记录解析结果 |

`gc` 在 SQLite 写锁内清理未引用的哈希资产和暂存文件；已提交引用仍被保留。维护前备份。运行目录下 `requests`、`validation` 为进程交接和校验暂存区，不是资产来源。所有故障注入仅在测试设置 `REGIONSTORE_TEST_FAULTS=1` 时生效，正常启动不设置它。

## 6. 复现验收

```powershell
python .\services\Test-Store.py --store $store --godot $godot --project .\prototype\godot --output 'D:\Tests\new SQLite acceptance'
& $godot --headless --path .\prototype\godot --log-file 'D:\Tests\adapter.log' `
  --script res://tests/sqlite_adapter.gd -- --directory='D:\Tests\new adapter' --store=$store
.\prototype\tools\Test-RegionLab.ps1 -Godot $godot -Visual
```

测试包括真实进程竞争、事务中断、提交后进程退出、迁移回滚、资产缺失/损坏、恶意导出包拒绝及搬移恢复。进程终止不等价于突然断电；不宣称已验证硬件断电持久性。

公开桌面入口复测（使用已经恢复且内容已知的隔离数据库）：

```powershell
.\services\Test-DesktopStore.ps1 -Database $restored -StoreExecutable $store -Godot $godot `
  -FixtureSnapshot 'D:\Tests\new SQLite acceptance\fixture.snapshot.json' -EvidenceDirectory 'D:\Tests\new desktop restore'
```

该测试启动正式脚本并核对实际加载结果，包含数据库路径、对象/组数量、网格资产、修订及已保存状态；同时保存真实渲染图。
