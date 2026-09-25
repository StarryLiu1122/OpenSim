# 将现有 OpenSim OAR 做成 V6 区域预览

V6 Region Lab 不能直接加载 OAR，也不是 Firestorm 服务器。本工具把 **一个 256 × 256 米 OAR 区域**的地形和部分 linked prim 变成 V6 内置几何体，便于在共享客户端检查空间布局。它不迁移贴图、雕塑网格、脚本、交互、库存、地块权限或完整链接结构。需要完整原貌时，仍应在 OpenSim/Firestorm 加载原 OAR。

本地北大课程场景试验：源 OAR 的 SHA256 为 `4bd00382788857214ee87f5791fc3b69e55aa23ae23ae9cc6a4dcaa155aece33`；生成了 65 × 65 地形采样和 361 个近西门的简化对象。它是课程包中的校园模型预览，**没有证据证明其坐标与今天的真实北大地理测绘一致**。课程包的再分发授权也未核实，所以 OAR 和由它产生的世界文件只放在本地 `prototype/runtime/`，不提交到仓库。

## 在新的隔离实例导入

在仓库根目录运行。先按 [网络运行指南](network-quickstart.md)准备 Godot 4.5.1、RegionStore 和 RegionHost。下面的变量换成自己的绝对路径；`$instance`、`$world` 和 `$report` 必须指向尚不存在的新文件或目录。

```powershell
$oar = 'C:\path\to\campus.oar'
$world = Join-Path $PWD 'prototype\runtime\campus-preview\world.json'
$instance = Join-Path $PWD 'prototype\runtime\campus-preview\instance'
$godot = 'C:\path\to\Godot_v4.5.1-stable_win64_console.exe'
$store = 'C:\path\to\RegionStore.exe'
$hostExe = 'C:\path\to\RegionHost.exe'
$report = Join-Path $PWD 'prototype\runtime\campus-preview\save-report.json'

python .\prototype\tools\Build-OarPreview.py $oar $world --focus 34 160 --limit 450
.\prototype\tools\Initialize-Network.ps1 -Directory $instance -Godot $godot `
  -Store $store -HostExecutable $hostExe -Port 19760
.\services\Invoke-Store.ps1 -Operation save -Root (Join-Path $instance 'storage') `
  -StoreExecutable $store -Godot $godot -Project .\prototype\godot `
  -InputFile $world -ExpectedCommit -1 -RequestId ([guid]::NewGuid().ToString()) -Report $report
.\prototype\tools\Start-Network.ps1 -Directory $instance
.\prototype\tools\Start-NetworkClient.ps1 -Directory $instance -Profile editor-a
```

先查看 `$report` 的 `ok: true` 与 `world_revision`，再启动服务。若写入结果不确定，按 [RegionStore 说明](../../services/README.md)用**同一请求 ID**查询或原样重试；不要用新的 ID 猜测重发。客户端初始镜头朝向区域出生点。当前世界支持单个 256 × 256 或 512 × 512 米区域、最多 500 个对象和 64 个导入网格资产，完整快照限 8 MiB；需要完整校园尺度，要先完成多区域管理、流式加载和层级细节（LOD）。

## 取得有明确来源的真实建模数据

| 用途 | 来源 | 导入路径 |
| --- | --- | --- |
| 真实道路与建筑轮廓 | [OpenStreetMap 导出](https://wiki.openstreetmap.org/wiki/Export)；数据依 ODbL 使用并署名 | 用 [BlenderGIS 的 OSM 导入](https://github.com/domlysz/BlenderGIS/wiki/OSM-import)取得轮廓，给建筑补高度并切成 256 米分块，再转换为 V6 可用的简化模型。地图轮廓不能当成带贴图的建筑扫描件。 |
| 有高度的真实城市建筑 | [荷兰 3DBAG 下载](https://3dbag.nl/download) | 按城市片区裁切、减面、转换为 GLB；逐一核对所选数据集的许可与来源。 |
| 文化遗产扫描 | [Open Heritage 3D](https://openheritage3d.org/faq) | 按每个项目的许可下载，减面并重烘贴图后再导入。原始扫描通常远超 V6 当前单模型预算。 |
| 通用树木、家具、材质 | [Poly Haven](https://polyhaven.com/license) | 其资源为 CC0；适合补充细节，但不能把通用素材称作某一真实建筑的测绘模型。 |

目前桌面 UI 可选择静态 GLB 或 glTF（支持同目录 BIN/PNG/JPEG 依赖），Web UI 仍只接收单文件 GLB；打包后每个资产最多 2 MiB，几何体与碰撞代理合计最多 20,000 个三角形，单轴尺寸需在 0.2–32 米之间。PNG/JPEG 底色、法线、金属粗糙度及遮蔽贴图可随文件导入。导入前应在 Blender 等工具中按区域裁切、合并重复实例、减面和烘焙贴图，保留资源许可与署名。大规模真实场景的下一步应是多区域与 LOD 基础能力，而非把整座校园硬塞入一个 GLB。
