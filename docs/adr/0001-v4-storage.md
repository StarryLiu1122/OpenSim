# ADR 0001：V4 采用本机 SQLite、C# 仓储进程与 GDScript 校验

日期：2026-09-16。状态：已实施并经事务、进程故障和独立目录恢复验证。应用版本 0.4.2。

## 背景

现有客户端使用 Godot 4.5.1/GDScript，本机 JSON 快照已能保留区域、对象组、地形和内嵌 GLB。V4 要验证事务、冲突、资产外置与可搬移恢复；真实平台的服务框架、数据库运维条件和认证接口尚未提供。原版 OpenSim 对照工具已需要 .NET 8，不能以语言更新为由重写客户端和验证规则。

## 选择

| 候选 | 适用性与取舍 |
| --- | --- |
| 继续只用 JSON | 保留为默认离线路径；适合一份文件保存世界，不提供两个写进程的数据库事务 |
| SQLite | 本轮选择；无独立数据库服务，可在同一事务中执行提交号比较、组/成员/引用发布，易建立故障与搬移测试；单写者，不作为高并发服务容量承诺 |
| PostgreSQL | 保留给 V5 服务端部署评估；当前引入账号、服务进程、备份运维和远程协议会扩大验收范围，真实平台环境未确认 |
| 在 Godot 中接入原生 SQLite 插件 | 增加 Godot 扩展及各平台二进制维护；本轮不采用 |
| Python 独立服务 | 容易编写工具，但会新增运行依赖，仍需解决 GDScript 规则复用；不作为运行框架 |

使用 C# net8.0 **命令行进程**而非常驻网络服务。SDK 8.0.424 固定于 `services/global.json`；Microsoft.Data.Sqlite 10.0.12 及传递依赖由 NuGet lock 的版本和 contentHash 固定。实测运行时 Microsoft.NETCore.App 8.0.30，SQLite `sqlite_version()` 为 3.53.3。后者为包内实际版本记录，不推断其他安装环境必然一致。

SQLite 表保存规范化身份、组/成员/资产关系和记录 JSON；GLB 按 SHA256 存文件。选择 WAL、`synchronous=FULL`、外键及 3 秒写锁等待。单区域完整候选为事务边界，读取与垃圾回收也协调写锁，优先正确性，接受验证/导出时阻塞写者的局限。

候选由独立 Godot headless 进程调用**同一份生产 WorldSchema、SnapshotRepository 和 GLB 校验器**。C# 负责传输限额、重复键、事务、哈希和包安全检查，不另写近似世界校验器。已为当前格式保留原 JSON 数值，避免校验往返造成无意义浮点改写；旧格式才使用原生迁移输出。

## 后果与退出路径

- JSON 桌面模式仍仅需 Godot；SQLite 模式另需 .NET 8 运行时，构建需 SDK/NuGet。Python 只用于可选验收和资产再生成。
- 校验启动进程有延迟，桌面保存当前同步等待；不承诺高频自动保存、低延迟网络提交或多人服务性能。
- 不改变世界格式 3；仓储接口、存储提交号、世代和导出包隔离数据库细节。未来可在服务端重用合同，替换 SQL 后端和内容存储；实际迁移仍需重新验收。
- 事务不能包住外部文件系统：先发布已验证不可变内容，再提交引用；失败可留孤儿，由持有相同写锁的维护命令回收。断电语义需要专门硬件测试，本轮只验证进程终止。
- `expected_commit` 和 request_id 的去重记录同事务写入；提交成功但确认丢失可原样重试。不能通过重生成 UUID 掩盖结果未知。

依据：[SQLite 事务](https://www.sqlite.org/lang_transaction.html)、[Microsoft.Data.Sqlite 概述](https://learn.microsoft.com/en-us/dotnet/standard/data/sqlite/)、[实现合同](../contracts/storage-v4.md)、[验收记录](../comparisons/v4-completion.md)。本决策只覆盖 V4 本机仓储，不预先选择 V5 的区域网络服务、完整身份系统或平台数据库。
