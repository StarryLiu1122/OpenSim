# 第三方运行依赖

项目代码遵循仓库原有许可；以下组件保留其各自许可。离线包制作脚本会一并带入 `services/licenses/`。这里只打包发布目录实际需要的组件和未修改的 Godot 官方归档，不把 Microsoft .NET 运行时作为包内文件分发。

| 组件 | 固定版本 | 来源/许可 |
| --- | --- | --- |
| Godot | 4.5.1 | [Godot 官方](https://github.com/godotengine/godot/tree/4.5.1-stable)，MIT；[许可全文](licenses/Godot.txt)；引擎内置组件的完整声明可在 Godot 的“关于/第三方许可”查看 |
| Microsoft.Data.Sqlite / Core | 10.0.12 | [EF Core](https://github.com/dotnet/efcore/tree/v10.0.12)，Microsoft，MIT；[许可全文](licenses/Microsoft.Data.Sqlite.txt) |
| SQLitePCLRaw core/bundle/provider/lib | 2.1.12 | [SQLitePCL.raw](https://github.com/ericsink/SQLitePCL.raw/tree/v2.1.12)，Copyright 2014–2024 SourceGear, LLC，Apache-2.0；[许可全文](licenses/SQLitePCLRaw.txt) |
| SQLite 原生数据库代码 | 运行时查询记录为 3.53.3 | [SQLite 公有领域说明](https://www.sqlite.org/copyright.html)；包的封装与构建仍保留 SQLitePCLRaw 声明 |
| System.Memory（锁定的传递构建依赖） | 4.5.3 | Microsoft，MIT；[许可全文](licenses/System.Memory.txt) |

NuGet 包校验以 [packages.lock.json](RegionStore/packages.lock.json) 的 contentHash 为准，离线发布文件另有 SHA256 清单。外部原版 OpenSim、Bot 库及其构建输出不装入桌面 SQLite 运行包；其源码许可分别保留在固定上游树及 [Bot 锁文件](../integration/opensim/client.lock.json) 对应来源中。
