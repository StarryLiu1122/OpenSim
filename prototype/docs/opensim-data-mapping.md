# OpenSim 数据模型对应说明

适用版本：Region Lab 0.3.0。参考源码：OpenSimulator 提交 `1f4a6dd1d3ff653ecc2748a7764106c30ac4ef9d`。

本文件定义当前原型与 OpenSim 概念的对应关系，标明已实现的数据范围及后续扩展边界。现阶段尚未提供旧数据库、OAR 或 Viewer 协议迁移能力。

## 1. 模块对应

| OpenSim 概念与源码 | Region Lab 实现 | 当前范围 |
| --- | --- | --- |
| [RegionInfo](../../OpenSim/Framework/RegionInfo.cs) | `region` | UUID、名称、尺寸、起点、归属；固定单区域 256×256 米 |
| [TerrainData](../../OpenSim/Framework/TerrainData.cs) | `terrain` | 高程数组、采样间距、行列数、保存恢复 |
| [TerrainModule](../../OpenSim/Region/CoreModules/World/Terrain/TerrainModule.cs) | TerrainBrush、SculptTerrain | 四种笔刷、区域归属检查、图形与碰撞更新；未复现原协议参数及全部笔刷算法 |
| [RegionSettings](../../OpenSim/Framework/RegionSettings.cs) | environment、EnvironmentView | 水位、太阳时刻、雾和地表显示；程序材质近似高度/坡度分层，未实现原纹理 UUID 或 EEP |
| [Scene](../../OpenSim/Region/Framework/Scenes/Scene.cs) | WorldModel、WorldService、main.gd | 世界状态、编辑命令及运行装配 |
| [SceneObjectGroup](../../OpenSim/Region/Framework/Scenes/SceneObjectGroup.cs)、[SceneObjectPart](../../OpenSim/Region/Framework/Scenes/SceneObjectPart.cs) | `objects[]` | 方块、圆柱、球与内置复合对象；变换、材质与归属；未实现 linkset、附件或完整 prim 参数 |
| [ScenePresence](../../OpenSim/Region/Framework/Scenes/ScenePresence.cs) | Avatar、CharacterBody3D | 本地角色、相机、输入及碰撞；未实现账户会话与外观库存 |
| [AssetBase](../../OpenSim/Framework/AssetBase.cs) | `assets[]` | 六项内置工厂目录，通过 asset_id 引用；未实现任意外部资产存储 |
| [InventoryItemBase](../../OpenSim/Framework/InventoryItemBase.cs)、[TaskInventoryItem](../../OpenSim/Framework/TaskInventoryItem.cs) | 后续库存实体 | 当前不包含库存记录、父对象关系和权限位 |
| [PhysicsScene](../../OpenSim/Region/PhysicsModules/SharedBase/PhysicsScene.cs) | WorldView、Avatar、Jolt | 静态对象、门状态碰撞、三角网格地形和角色；未实现车辆、约束和动态物体编辑 |
| [ISimulationDataStore](../../OpenSim/Region/Framework/Interfaces/ISimulationDataStore.cs) | SnapshotRepository | 完整区域快照及备份；未实现原数据库适配 |
| [SceneObjectPartInventory](../../OpenSim/Region/Framework/Scenes/SceneObjectPartInventory.cs)、[ScriptEngine](../../OpenSim/Region/ScriptEngine/) | 内置 door/lamp 状态 | 开关状态可存档，不包含脚本条目、LSL/OSSL 或任意事件处理程序 |

## 2. 实体和标识

| 字段 | 定义 |
| --- | --- |
| `region.id` | 区域 UUID；当前使用固定演示标识，尚无 Grid 注册 |
| `region.owner_id` | 区域归属；地形与环境命令校验该字段 |
| `objects[].id` | 物体实例 UUID，保存、恢复和历史操作保持一致 |
| `objects[].asset_id` | 资产定义标识；当前支持六项固定内置目录 |
| `objects[].owner_id` | 物体归属；修改、删除与行为命令校验该字段 |
| `objects[].position` | 区域内位置 `[东, 北, 高]`，米 |
| `objects[].rotation` | 数据坐标系下的单位四元数 `[x,y,z,w]` |
| `objects[].size` | 各轴尺寸，米；每轴 0.2–32 |
| `objects[].color` | 整体颜色 `#RRGGBB`，未实现分面材质 |
| `objects[].material` | 内置表面类型；不等价于 OpenSim 分面纹理条目 |
| `objects[].state` | door/lamp 的 active 状态，其它对象为空字典 |
| `objects[].name` | 1–80 字符的非空名称 |

Godot 节点只保存运行时映射。NodePath、节点实例编号及引擎指针不作为持久化标识。资产 ID 表示资源定义，库存条目还需独立身份、父级和权限，二者不可合并。

## 3. 坐标与旋转

区域数据采用 X 向东、Y 向北、Z 向上，单位米。Grid 全局位置尚未建模。WorldView 集中承担坐标转换：

```text
区域 [x, y, z]  → Godot (x, z, -y)
Godot (x, y, z) → 区域 [x, -z, y]
区域东北角 [256, 256, 0] → Godot (256, 0, -256)
```

旋转采用基变换 `B_engine = C × B_region × inverse(C)`。UI 当前只编辑绕区域 Z 轴的水平角；未修改旋转时保留原四元数。

物体的水平边界检查采用旋转后的完整包围范围。地形变化不自动修改物体变换；“放到地面”按物体中心查询地面并按半高放置，适用于当前直立对象，不是完整地基拟合。

## 4. 地形模型

种子地形采用 65×65 个高程样本、4 米间距和 64×64 个网格单元，覆盖 256×256 米。数组索引为 `north_index * columns + east_index`，包含最东和最北边界。采样分辨率与原版默认数据不同，未来导入需要显式重采样。

地形数据经过以下路径处理：

```mermaid
flowchart LR
    P[笔刷参数] --> C[SculptTerrain 命令]
    C --> H[候选高程数组]
    H --> V[校验与修订]
    V --> D[世界数据]
    D --> M[共享顶点与三角形索引]
    M --> R[ArrayMesh 显示]
    M --> J[ConcavePolygonShape3D / Jolt]
    D --> S[快照保存]
```

每次笔刷操作保存为一个历史步骤。平滑操作读取修改前的邻域数据，避免遍历顺序影响结果。显示网格、地面高度查询和碰撞体采用同一三角形划分，具体公式与参数见 [接口文档](architecture-and-api.md)。

V1 使用 HeightMapShape3D；V2 调整为共享三角形的静态碰撞体。该变化位于引擎适配层，存档仍保存高度场，V2 世界格式保持为 1。V3 因环境、材质及行为字段升级到格式 2，地形数组本身不变。

## 5. 创建、编辑与恢复

1. UI 或离线工具提交命令，Service 检查请求版本、重复请求和当前修订。
2. Model 检查归属及候选世界；验证通过后一次替换数据。
3. WorldView 更新物体或地形。地形更新保留物体节点及其变换。
4. Repository 保存区域、地形、环境、资产描述、物体材质和行为状态，不序列化运行时节点。
5. 恢复时验证封装、校验和及世界结构，再替换数据并重建场景；失败时保留内存世界。
6. 恢复后角色返回区域起点；若起点地形已抬升，角色被放置在地面上方。

OpenSim 的 `StoreObject` 不保存库存，库存通过 `StorePrimInventory` 单独持久化。当前快照只覆盖已定义实体；后续库存、脚本状态和完整权限需分别定义持久化与恢复规则。


## 6. 环境与行为的对应边界

RegionSettings 的 WaterHeight 为区域水面高度提供了明确参考；V3 使用米制 water_height，渲染为区域水平面。太阳时刻属于可视环境配置，未复刻原版 SunPosition、UseEstateSun 和 Viewer 环境协议的全部语义。TerrainTexture1–4 的外部纹理 UUID 尚未导入，现阶段以程序化草地、岸边与陡坡表面表达地表差异。

OpenSim 的门灯通常依赖物体属性及脚本事件。V3 将其缩小为两个可验证的内置行为：开门改变显示几何与通行碰撞，开灯改变原生局部灯光；状态随区域保存。没有复制脚本库存、事件队列、权限位或完整脚本生命周期。

示例展馆由独立对象组成，门是单一对象的引擎内部复合节点。这一结构不构成 SceneObjectGroup 的根部件/子部件关系，也不能与 OAR 数据直接互换。下一步先定义对象组合和局部变换，再实施外部资产和原版数据导入。
