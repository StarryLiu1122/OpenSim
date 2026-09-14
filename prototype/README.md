# Region Lab：OpenSim 单区域验证原型

使用 **Godot 4.5.1 标准版 + 内置 Jolt 物理 + GDScript**，实现一个能进入、编辑、保存并在重新启动后恢复的 256×256 米区域。界面与自动化调用共用同一个经过校验的世界命令入口。

本版本为 **本机、单用户、静态方块编辑原型**。包含角色重力/跳跃/碰撞、程序生成地形和方块编辑；尚未实现多人服务器、Firestorm 协议、地形画刷、外部模型导入、库存系统、LSL/OSSL 和 PostgreSQL。

![原型的实际 Godot 渲染截图](docs/images/overview.png)

## 1. 环境依赖

| 项目 | 要求与说明 |
| --- | --- |
| 已验证系统 | Windows 11 x64；Windows 10 x64 为目标兼容环境，未在本次机器上实测 |
| 引擎 | Godot **4.5.1 标准版**，版本输出 `4.5.1.stable.official.f62fdbde1`；不使用 .NET 版 |
| 图形 | 支持 OpenGL 3.3 的显卡和正常驱动；使用 Compatibility 渲染器 |
| 物理 | Godot 随附 Jolt，无需单独安装 |
| 脚本工具 | Windows 自带 PowerShell 5.1；已用此版本验证安装与测试脚本 |
| 网络 | 首次在线安装用于从 Godot 官方 GitHub 下载约 77 MB 压缩包；之后运行可离线 |
| 可选 | Git 用于克隆；也可在 GitHub 下载此分支 ZIP 后解压 |

运行此原型不需要先运行 OpenSim/Firestorm，也不需要 .NET SDK、Python、C++ 编译器、数据库、模型权重或 API Key。直接从 Godot 项目运行不需要额外下载导出模板。引擎与归档校验值固定在 [engine.lock.json](engine.lock.json)。

## 2. 安装与启动（Windows）

打开 PowerShell，执行：

```powershell
git clone --branch codex/single-region-prototype https://github.com/StarryLiu1122/OpenSim.git
cd OpenSim\prototype
.\Install.cmd
.\Start.cmd
```

如果已有仓库，先提交或保存自己的本地修改，再获取并切换到 `codex/single-region-prototype`，进入 `prototype` 目录。

也可以在文件管理器中先双击 `Install.cmd`，成功后双击 `Start.cmd`。安装脚本下载官方发行包，验证 SHA512、归档条目及两个可执行文件的校验值，再放入 `prototype/.tools/godot-4.5.1/`；不写系统 PATH，不需要管理员安装。

已有官方压缩包时，可以离线安装：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Install-Godot.ps1 -ArchivePath "D:\Downloads\Godot_v4.5.1-stable_win64.exe.zip"
```

启动自己的另一个世界文件：

```powershell
.\Start.cmd -WorldFile "D:\RegionLabData\my-region.json"
```

指定已有官方引擎，或打开工程编辑器：

```powershell
.\Start.cmd -Godot "D:\Godot\Godot_v4.5.1-stable_win64_console.exe"
.\Start.cmd -Editor
```

检查启动并保存一张实际引擎截图后自动退出（不自动保存世界）：

```powershell
.\Start.cmd -WorldFile "$PWD\runtime\launch-check.json" -Screenshot "$PWD\test-results\launch.png"
```

也可设置当前终端的 `GODOT_EXE` 环境变量。`Install.cmd` 和 `Start.cmd` 使用的执行策略参数只针对启动的 PowerShell 进程，不修改系统执行策略。

## 3. 五分钟验收

1. 启动后看到“青屿实验区”、左侧对象列表和右侧属性面板。
2. 点击“进入漫游”或按 Tab，使用 WASD 移动，空格跳跃，Shift 加速；接近方块时有真实碰撞。按 Esc 回到编辑。
3. 点击“添加立方体”。修改名字、位置、尺寸、水平旋转和颜色，点击“应用修改”。X 为东，Y 为北，Z 为高度，长度单位是米。
4. 点击“保存世界”，确认顶部出现“保存成功”。可在“操作指南”中查看实际存档路径。
5. 再修改方块但不保存，点击“恢复存档”并确认；属性恢复为之前保存的值。
6. 保存后正常关闭程序，再启动。对象 ID、名字、位置、尺寸、旋转和颜色仍应一致。
7. 删除一个方块，再按 Ctrl+Z，检查同一对象恢复。删除后保存并重启，已删除对象应继续不存在。

| 操作 | 按键 / 入口 |
| --- | --- |
| 选择 | 点击三维方块或左侧列表 |
| 旋转编辑视角 | 按住鼠标右键拖动 |
| 平移 / 缩放 | 鼠标中键拖动 / 滚轮 |
| 聚焦选择 | F；或双击列表条目 |
| 复制 / 删除 / 撤销 | Ctrl+D / Delete / Ctrl+Z；也有按钮 |
| 保存 / 恢复 | Ctrl+S / Ctrl+O；也有按钮 |
| 漫游 / 返回编辑 | Tab / Esc |

编辑属性需要点击“应用修改”。仅在数值框中输入但尚未应用的文字，不属于世界状态，也不会被“保存世界”写入。保存的是世界数据，不包含当前编辑相机、选择状态、撤销历史或角色实时位置；重新进入时角色回到区域起点。

## 4. 存档与恢复

默认路径为 `%APPDATA%\OpenSimRegionLab\worlds\default.json`。可在操作指南查看本机解析后的路径，或用 `-WorldFile` 选择独立路径。不要让两个实例同时写同一个存档。

- `.json` 为当前存档；`.json.bak` 为上一次有效存档；`.tmp` 为写入中间文件。
- 先验证数据、写临时文件、回读验证，再更新备份并替换主文件。主文件损坏时不会覆盖有效备份。
- 启动或恢复时，主文件不可用会尝试有效备份，并在界面显示恢复提示；两者均无效时返回错误。
- 存储封装包含 `format`、`version`、`sha256`、`world_json`。`world_json` 是 JSON 文本字符串，SHA256 针对它的原始 UTF-8 文本计算，避免浮点数重新序列化影响校验。
- 这是单写入者快照存储。能够发现已经发生的外部文件修改，但没有跨进程锁或数据库事务，不能用作多人共享数据库。
- 检查和恢复的是程序级写入、格式及文件一致性；没有验证断电场景的操作系统持久性保证。

需要新建另一份演示世界时，使用一个不存在的 `-WorldFile` 路径；首次保存前不要手工覆盖已有数据。

## 5. 自动化测试与 AI 调用入口

运行不需要图形窗口的原生数据、存储、物理及独立进程测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-RegionLab.ps1
```

同时运行实际图形界面控件和截图检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-RegionLab.ps1 -Visual
```

测试为每次运行创建唯一的 `test-results/run-.../` 目录，不使用默认用户存档。报告包含失败数、独立进程恢复结果、离线命令调用结果；图形检查还生成 `overview.png` 和 `edited.png`。脚本不仅检查退出码，还要求报告存在、检查数满足预期且没有引擎错误。

提供了可供编程智能体或普通脚本调用的离线 JSON 命令适配器。以下示例应使用一个新的文件路径，并在图形程序关闭时运行：

```powershell
$engine = ".\.tools\godot-4.5.1\Godot_v4.5.1-stable_win64_console.exe"
& $engine --headless --path .\godot --script res://tools/world_cli.gd -- `
  "--world-file=$PWD\runtime\automation-demo.json" `
  "--commands=$PWD\fixtures\create-and-save.commands.json" `
  "--output=$PWD\runtime\automation-report.json"
.\Start.cmd -WorldFile "$PWD\runtime\automation-demo.json"
```

示例使用固定对象 ID；对同一文件重复运行会明确报告重复 ID，不会悄悄再建一个对象。更多接口说明见 [架构与命令契约](docs/architecture-and-api.md)。

## 6. 文档与实现入口

- [引擎选择与 GameFactory 借鉴](docs/engine-decision.md)
- [OpenSim 数据结构对应说明](docs/opensim-data-mapping.md)
- [架构、命令及存档契约](docs/architecture-and-api.md)
- [验证记录和边界](docs/verification.md)
- [第一阶段原始计划](../docs/plans/stage-one-rebuild-plan.md)

```text
godot/domain/        世界格式、数据校验、状态与命令服务
godot/adapters/      场景/碰撞适配、快照存储
godot/client/        角色、中文编辑界面
godot/tools/         离线 JSON 命令入口
godot/tests/         原生数据/物理、独立进程、UI 测试
tools/              Windows 安装、启动、测试脚本
fixtures/           最小命令样例
docs/               选择依据、对应说明与真实验证证据
```

## 7. 常见问题

- **找不到 Godot：** 先运行 `Install.cmd`，或用 `-Godot` 指定固定版本的 console 可执行文件。
- **下载失败：** 从 [Godot 官方发行页](https://github.com/godotengine/godot-builds/releases/tag/4.5.1-stable)下载同名 Windows x64 标准版压缩包，再用 `-ArchivePath` 安装。校验失败时停止，不跳过校验。
- **窗口打不开或黑屏：** 核实 OpenGL 3.3 驱动；远程桌面或无图形会话可能无法运行视觉测试，可先执行非视觉测试。CPU 测试通过不表示图形环境已验证。
- **中文显示方框：** 界面优先使用系统的 Microsoft YaHei 字体，未将系统字体打包入库；其它系统需提供相应中文字体。
- **修改被拒绝：** 查看错误提示。物体尺寸必须在 0.2–32 米之间，旋转后的完整水平包围范围必须留在区域内；不允许修改所有者 ID。
- **打开原版 C# 解决方案：** 那是研究基线，运行当前原型应打开 `prototype/godot/project.godot`。

本机版本尚未进行 Linux、macOS、浏览器导出或独立发行包验证。下一步优先补原版运行对照、地形编辑与数据库持久化，再进入多人同步和更完整的权限/脚本体系。
