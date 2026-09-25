# 赫尔辛基实景街区样例

这是一个比代尔夫特建筑样例更大的真实地点演示：从赫尔辛基市 2017 年航拍生成的带纹理三维网格中，选取连续 **125×125 米**的街区，保留建筑、道路、树木和原始照片纹理。它由 16 个约 31.25 米的 GLB 组成，共约 3.3 万个三角面，在 Region Lab V6 的 256×256 米单区中展示。

![V6 桌面客户端中的赫尔辛基实景街区](images/helsinki-kamppi-textured.png)

## 打开

在 Windows 文件管理器中双击 `prototype/打开赫尔辛基实景街区.cmd`。它首次运行会生成隔离的 `prototype/runtime/helsinki-kamppi-v3` 存档和网络实例；之后复用同一实例。进入窗口后点击「知道了，收起指南」，再点击「进入漫游」或按 Tab；WASD 移动，Esc 返回编辑视角，鼠标滚轮可缩放俯瞰视角。

若服务程序或 Godot 未安装，先按[网络运行指南](network-quickstart.md)构建并安装。与代尔夫特实例同时运行时，此入口使用另一组端口 `20820–20822`。

## 来源与转换

- 来源为[赫尔辛基市官方 3D Mesh 开放数据](https://www.hel.fi/en/decision-making/information-on-helsinki/maps-and-geospatial-data/helsinki-3d)中的 [2017 OBJ 压缩包 `672494x2`](https://3d.hel.ninja/data/mesh/Helsinki3D-MESH_2017_OBJ_2km-250m_ZIP/Helsinki3D_2017_OBJ_672494x2.zip)，子目录 `672495a3` 的 LoD 19 网格。市政府说明，这份网格由航拍照片制作，按 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) 开放。
- ZIP 的 `metadata.xml` 将坐标标为 `EPSG:3879+5773`，其中 [EPSG:5773 是 EGM96 高程](https://epsg.io/5773)；[市政府的总体说明](https://www.hel.fi/en/decision-making/information-on-helsinki/maps-and-geospatial-data/helsinki-3d)则称该模型使用 N2000。这里忠实记录源文件标签，未对两种高程基准作绝对转换。片区在来源模型局部坐标中的边界为东 `5312.5–5437.5` 米、北 `4093.75–4218.75` 米；模型原点是东 `25490000`、北 `6668000` 米。模型在 Region Lab 中平移至东 `64–189`、北 `32–157` 米，减去统一来源高程基准。相对位置与 1:1 米制尺寸保持不变。
- `tools/Convert-HelsinkiMesh.py` 将来源 OBJ 的三角形和 UV 转成 16 个内嵌 JPEG 的 GLB。照片纹理像素未重新绘制。每块 GLB 的 SHA-256、原始 OBJ/JPEG 文件名与 SHA-256 都记录在 [`manifest.json`](../fixtures/geodata/helsinki-kamppi-textured/manifest.json)。仓库保存转换后的约 1.4 MB 样例资源，不保存完整源 ZIP。
- 复现时，从官方 ZIP 解压 `672495a3/*_L19_*` 的 OBJ 与 JPEG 到一个目录，然后运行 `python prototype/tools/Convert-HelsinkiMesh.py <解压目录> <全新输出目录>`。`build_city_pilot.gd` 通过 `WorldService` 命令导入资源、摆放网格、设置区域名称和安全出生点，再保存存档。

**署名：© City of Helsinki, Helsinki 3D Mesh 2017，CC BY 4.0。** 本项目所做的改动包括截取 16 个网格、坐标平移与轴转换、OBJ/JPEG 封装为 GLB，以及设置独立演示区域。客户端底部会显示来源入口。

这是 2017 年航拍网格的一个静态片段，不代表当前建筑现状。片区以外仍为原型自带的程序地形；模型边缘可能出现航拍重建缝隙，建筑室内没有单独建模。导入上限现为 64 个资产，但完整快照仍限 8 MiB；此 16 块演示保留为轻量入口。系统尚不能连续加载整座城市或通用 3D Tiles。

## V7：250 × 250 米扩展场景

![64 块纹理网格在网络客户端实际渲染的 250 米场景](images/helsinki-kamppi-250m.png)

[`helsinki-kamppi-250m/manifest.json`](../fixtures/geodata/helsinki-kamppi-250m/manifest.json) 和同目录 64 个 GLB 是从同一官方来源的完整 8 × 8 LoD 19 网格转换而来，源范围为东 `5250–5500`、北 `4000–4250` 米。地块放置于 512 × 512 米区域中心，东、北偏移均为 128 米。原始 OBJ/JPEG 的摘要、许可、转换结果摘要和坐标基准都在清单中。它包含 114,457 个三角形、4.86 MB GLB；完整世界快照约 6.93 MB。纹理与模型都是 2017 年航拍数据，没有补绘建筑细节。

在 Windows 双击 [`打开赫尔辛基250米实景.cmd`](../打开赫尔辛基250米实景.cmd)。首次运行约需几十秒构建独立存档并启动服务；之后复用 `prototype/runtime/helsinki-kamppi-v7-250m`。进入窗口后按 Tab 漫游，WASD 移动，Esc 返回编辑视角。该入口使用 `20830–20832` 端口，不会覆盖上方 125 米场景。

复现：`python prototype/tools/Convert-HelsinkiMesh.py <672495a3源目录> <全新输出目录> --grid-x=0 --grid-y=0 --count=8`。再用 `build_city_pilot.gd` 的 `--manifest`、`--world-file` 和 `--report` 参数构建独立世界；也可直接使用仓库内的 64 块转换结果。此场景的网格资产正好用满 64 个槽位，接近 8 MiB 快照上限；更大区域必须先实现资产仓储与分块加载。客户端已有独立网络实例验证 64 块模型、64 张纹理和可行走出生点，不能据此宣称低端设备帧率或近距离摄影测量质量达标。
