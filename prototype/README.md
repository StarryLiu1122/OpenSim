# Region Lab V3 使用说明

版本：0.3.0。本文适用于 Windows x64 源码运行方式。

Region Lab 是基于 Godot 的单区域编辑原型。V3 支持六类对象、程序材质、地形编辑、区域环境、门灯交互、角色漫游和统一保存恢复。新世界提供庭院、湖岸及可进入的展馆。区域尺寸为 256×256 米，当前采用本机单用户模式。

## 1. 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows x64；已验证 Windows 11 10.0.26200，Windows 10 尚未实测 |
| 图形 | 支持 OpenGL 3.3 的显卡和正常驱动；采用 Compatibility 渲染器 |
| 引擎 | Godot 4.5.1 标准版，版本号 `4.5.1.stable.official.f62fdbde1` |
| 物理 | 引擎内置 Jolt，无独立安装项 |
| 命令环境 | Windows PowerShell 5.1；CMD 入口兼容从 PowerShell 7 调用 |
| 网络 | 在线安装时下载官方引擎包，约 77 MB；安装后可离线运行 |
| 可选工具 | Git，用于克隆和更新代码 |

版本及 SHA512 固定在 [engine.lock.json](engine.lock.json)。运行不需要 .NET SDK、Python、C++ 编译器、数据库、模型权重或 API Key。当前直接运行工程，不需要导出模板。

## 2. 安装

### 2.1 获取代码

```powershell
git clone --branch codex/region-lab-v3 https://github.com/StarryLiu1122/OpenSim.git
cd OpenSim\prototype
```

也可在 GitHub 下载该分支 ZIP 并解压。已有仓库可在保存本地修改后，获取并切换至 `codex/region-lab-v3`。

### 2.2 安装引擎

```powershell
.\Install.cmd
```

脚本从官方发行地址下载压缩包，验证归档布局、压缩包及可执行文件的 SHA512，安装至 `.tools/godot-4.5.1/`。安装仅写入项目目录，不修改系统 PATH 或系统执行策略。已安装且校验通过时直接复用。

离线安装：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Install-Godot.ps1 -ArchivePath "D:\Downloads\Godot_v4.5.1-stable_win64.exe.zip"
```

压缩包必须来自 [Godot 4.5.1 官方发行页](https://github.com/godotengine/godot-builds/releases/tag/4.5.1-stable)，文件名为 `Godot_v4.5.1-stable_win64.exe.zip`。

## 3. 启动

```powershell
.\Start.cmd
```

文件管理器中可双击 `Start.cmd`。以下参数用于指定世界、引擎或编辑器：

```powershell
.\Start.cmd -WorldFile "D:\RegionLabData\demo.json"
.\Start.cmd -Godot "D:\Godot\Godot_v4.5.1-stable_win64_console.exe"
.\Start.cmd -Editor
```

也可通过当前终端的 `GODOT_EXE` 指定引擎。使用新的 `-WorldFile` 路径将创建一份独立演示世界；首次保存前只存在于内存。

启动检查可输出一张画面后自动退出，不自动保存世界：

```powershell
.\Start.cmd -WorldFile "$PWD\runtime\launch-check.json" -Screenshot "$PWD\test-results\launch.png"
```

## 4. 物体与角色操作

左侧为对象列表，右侧“对象”页显示所选对象属性。属性输入完成后，点击“应用修改”提交至世界状态。仅输入但未应用的数值不会被保存。

| 操作 | 入口 |
| --- | --- |
| 创建、复制、删除 | 左侧按钮；复制 Ctrl+D，删除 Delete |
| 选择类型 | 左侧下拉框：方块、圆柱、球、伸缩门、树木、路灯 |
| 门灯交互 | 编辑模式选择对象后点击开启/关闭；漫游模式对准 4 米内的门框或路灯，按 E |
| 选择对象 | 单击场景物体或列表条目 |
| 编辑属性 | 名称、位置、尺寸、水平旋转、颜色和材质，编辑后应用 |
| 聚焦 | F 或双击列表 |
| 编辑视角 | 右键旋转、中键平移、滚轮缩放 |
| 漫游 | Tab 进入，WASD 移动，空格跳跃，Shift 加速，Esc 返回 |
| 撤销 / 重做 | Ctrl+Z / Ctrl+Y，或底部按钮 |
| 保存 / 恢复 | Ctrl+S / Ctrl+O，或顶部按钮 |

坐标单位为米，X 向东、Y 向北、Z 为高度。物体每轴尺寸为 0.2–32 米，旋转后的完整水平范围必须位于区域内。

### 4.1 首次体验

1. 使用一个新的存档路径启动，例如 `Start.cmd -WorldFile "$PWD\runtime\v3-demo.json"`。已有 V1/V2 存档将保留原场景，不自动替换为展馆。
2. Tab 进入漫游，沿道路向前走到展馆入口。漫游时隐藏两侧编辑面板。
3. 在 4 米内对准门或门框，按 E 开门，继续向前进入室内。打开后门洞中央为空，应对准门框关闭。
4. Esc 返回编辑。在“环境”页设置 20 时，点击“应用环境设置”，观察路灯与夜景。
5. 保存世界，关闭后用同一路径重新启动，核对环境与门灯状态。

展馆各墙体、屋顶和陈设可分别选择编辑。它们尚未组成 linkset；整体移动建筑需要后续对象组功能。

### 4.2 区域环境

| 设置 | 范围与作用 |
| --- | --- |
| 太阳时刻 | 0–24；6 时日出、12 时正午、18 时日落；固定时刻，不自动推进，也不计算真实地理日照 |
| 水位 | -40–80 米；整个区域共用水平水面 |
| 水面开关 | 控制水面显示；地形与物体不随水位变化 |
| 雾密度 | 0–0.02，0 关闭 |
| 地形网格 | 编辑辅助线，可按需开启 |

环境操作与物体、地形共用撤销和重做。水面为视觉效果，当前没有游泳、浮力、潮汐或水流。树木仅树干参与碰撞；叶冠不阻挡角色。门使用内置伸缩状态，不执行外部脚本。

![V3 区域场景](docs/images/overview.png)

## 5. 地形编辑

点击左侧“地形编辑”，或切换右侧“地形”页。

1. 选择笔刷类型，设置半径和强度。设高模式还需填写目标高程。
2. 在地表单击应用一次笔刷；也可填写中心 X、Y 后点击“应用笔刷”。黄色轮廓表示操作范围。
3. 检查地形结果，按需撤销或重做。
4. 点击“保存世界”。重新启动或恢复存档后，编辑后的地形与物体一起恢复。

| 笔刷 | 效果 |
| --- | --- |
| 抬升 | 增加高程；中心单次最大增量为 8 米乘以强度 |
| 降低 | 减小高程；中心单次最大减量为 8 米乘以强度 |
| 设高 | 按强度向目标高程混合；100% 强度时中心达到目标值 |
| 平滑 | 按强度向原高度场的 3×3 邻域均值混合 |

笔刷半径为 4–32 米，强度为 5%–100%，高程范围为 -40–80 米。作用随距中心距离增加而衰减，边界外采样不参与操作。地形采用 4 米采样间距，因此小范围编辑呈现网格分辨率限制。

**每次单击是一条编辑命令，当前不支持按住鼠标连续涂抹。** 笔刷仅修改地形；物体保持原坐标。抬升地形可能遮挡已有物体，可在“对象”页调整位置或使用“放到地面”。地形抬升到角色脚下时，程序将角色抬至地面上方，并保留水平位置。

![地形编辑界面](docs/images/terrain.png)

## 6. 保存与版本兼容

默认存档为 `%APPDATA%\OpenSimRegionLab\worlds\default.json`。界面“操作指南”显示实际路径；`-WorldFile` 可指定独立文件。

| 文件 | 用途 |
| --- | --- |
| `*.json` | 当前世界 |
| `*.json.bak` | 上一次有效世界 |
| `*.json.tmp`、`*.json.bak.tmp` | 写入期间的中间文件 |

保存流程包括数据校验、临时写入、回读验证、有效备份更新和主文件替换。主存档无效时尝试备份；恢复备份后界面提示检查并保存。两份文件均无效时保留当前内存世界并报告错误。

V3 使用世界格式版本 2，可读取 V1/V2 的格式 1 存档。读取时先验证旧结构、在内存中补齐环境、材质和行为字段，并标记为待保存；原文件此时不改写。首次保存升级结果时，原格式保留在 .bak。V1/V2 程序不能读取格式 2；如需返回旧版，应使用升级前副本或尚未被后续保存轮换的旧备份。不要让两个程序实例同时写入同一世界文件。快照为单写入者存储，外部修改检测不提供跨进程事务保证。

保存内容包括区域、地形、环境、内置资产目录、物体材质和门灯状态。编辑相机、角色实时位置、选择状态和撤销历史不持久化；角色重新启动时位于区域起点。撤销或重做后的世界按已修改状态处理，保存后清除标记。

## 7. 测试与自动化

数据、物理、兼容性、跨进程及批处理测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-RegionLab.ps1
```

增加界面事件与渲染测试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-RegionLab.ps1 -Visual
```

每次运行输出至独立的 `test-results/run-.../`，包括汇总 JSON、各项检查、引擎日志和截图。测试不使用默认用户存档。当前结果见 [验证记录](docs/verification.md)。

离线地形命令样例：

```powershell
$engine = ".\.tools\godot-4.5.1\Godot_v4.5.1-stable_win64_console.exe"
& $engine --headless --path .\godot --script res://tools/world_cli.gd -- `
  "--world-file=$PWD\runtime\terrain-demo.json" `
  "--commands=$PWD\fixtures\sculpt-and-save.commands.json" `
  "--output=$PWD\runtime\terrain-report.json"
.\Start.cmd -WorldFile "$PWD\runtime\terrain-demo.json"
```

批处理应在图形程序关闭后执行。创建物体样例另见 [create-and-save.commands.json](fixtures/create-and-save.commands.json)，环境与开门样例见 [environment-and-door.commands.json](fixtures/environment-and-door.commands.json)，命令语义见 [接口文档](docs/architecture-and-api.md)。

## 8. 常见故障

| 现象 | 处理 |
| --- | --- |
| 找不到引擎或版本不符 | 运行 `Install.cmd`，或指定固定版本的 console 可执行文件 |
| 下载失败或校验失败 | 从官方发行页下载同名压缩包后离线安装；保留校验检查 |
| 黑屏、图形初始化失败 | 检查 OpenGL 3.3 驱动；无图形会话可先运行非视觉测试 |
| 中文显示方框 | 界面使用系统中文字体，Windows 优先 Microsoft YaHei；未随仓库分发字体 |
| 属性变化未保存 | 先点击“应用修改”或“应用笔刷”，再保存世界 |
| 地形操作没有变化 | 检查高程上限、笔刷模式、强度与采样分辨率；无变化操作不增加历史 |
| 保存时报告外部修改 | 从磁盘恢复后再编辑，或为另一实例指定不同存档 |

## 9. 相关文档

[架构与接口](docs/architecture-and-api.md) · [数据对应](docs/opensim-data-mapping.md) · [技术选型](docs/engine-decision.md) · [V3 版本说明](docs/releases/v3.md) · [后续计划](../docs/plans/stage-one-rebuild-plan.md)
