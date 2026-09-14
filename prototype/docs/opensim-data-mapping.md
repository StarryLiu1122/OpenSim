# OpenSim 数据结构与原型的对应说明

研究基线为上游提交 `1f4a6dd1d3ff653ecc2748a7764106c30ac4ef9d`。本表来自源码阅读及新原型测试，是概念和行为的对应说明，不是旧数据库或 OAR 的迁移工具，也不代表已完成原版运行对照。

## 1. 分层对应

| OpenSim 概念与源码入口 | 当前原型 | 已实现 / 尚缺部分 |
| --- | --- | --- |
| [RegionInfo](../../OpenSim/Framework/RegionInfo.cs) 的 UUID、尺寸等 | `world.region.id/name/size/spawn/owner_id` | 单区域；尺寸作为字段存储，当前校验仅接受 256×256 米；无 Grid 全局路由 |
| [TerrainData](../../OpenSim/Framework/TerrainData.cs) 的高度场与存储修订 | `world.terrain`，WorldView 的地形网格和 HeightMapShape3D | 保存高度数据、生成图形和碰撞；无原二进制格式导入、地形画刷或修改分块同步 |
| [RegionSettings](../../OpenSim/Framework/RegionSettings.cs) 的地形/环境设置 | 当前程序地形材质和固定灯光 | 视觉演示；未复现原纹理分层和完整环境设置 |
| [Scene](../../OpenSim/Region/Framework/Scenes/Scene.cs) 组织世界 | `WorldModel`、`WorldService`、`main.gd` | 数据生命周期、命令、界面装配；无区域服务器调度和网络模块 |
| [SceneObjectGroup](../../OpenSim/Region/Framework/Scenes/SceneObjectGroup.cs) 与 [SceneObjectPart](../../OpenSim/Region/Framework/Scenes/SceneObjectPart.cs) | `world.objects[]` 加一个 StaticBody3D/BoxMesh/BoxShape3D 映射 | 一个记录对应简化的单部件物体；未支持 linkset、附件、复杂 prim 或网格 |
| [ScenePresence](../../OpenSim/Region/Framework/Scenes/ScenePresence.cs) | `avatar.gd` 的 CharacterBody3D、输入和相机 | 本地移动、重力、跳跃、碰撞；无登录会话、外观库存或区域穿越 |
| [AssetBase](../../OpenSim/Framework/AssetBase.cs) | `assets[]` 中的固定 unit-box 描述，物体用 `asset_id` 引用 | 区分资产定义和物体实例；未提供外部资产上传/下载服务 |
| [InventoryItemBase](../../OpenSim/Framework/InventoryItemBase.cs)、[TaskInventoryItem](../../OpenSim/Framework/TaskInventoryItem.cs) | 尚未实现库存实体 | 不能把 `asset_id` 当成库存条目 ID；库存的归属、父对象、权限和脚本引用另行实现 |
| [PhysicsScene](../../OpenSim/Region/PhysicsModules/SharedBase/PhysicsScene.cs) 的物理接口 | `world_view.gd` 封装 Jolt 原生形状，`avatar.gd` 调用移动求解 | 地形、静态物体、角色碰撞；无动态物体、车辆、约束或旧物理参数兼容 |
| [ISimulationDataStore](../../OpenSim/Region/Framework/Interfaces/ISimulationDataStore.cs) | `SnapshotRepository` | 单区域完整快照及备份；无数据库迁移、多人事务或原始库存存储 |
| [SceneObjectPartInventory](../../OpenSim/Region/Framework/Scenes/SceneObjectPartInventory.cs)、[ScriptEngine](../../OpenSim/Region/ScriptEngine/) | 尚未实现世界内脚本 | GDScript 是实现代码，不是 LSL/OSSL 兼容层或用户脚本沙箱 |

注意：本文件位于 `prototype/docs/`，上表链接需要返回仓库根目录；源码仍完整保留在根目录的 `OpenSim/` 下。

## 2. 物体字段

| 字段 | 含义 / 单位 | 对应原版语义 |
| --- | --- | --- |
| `id` | 创建时生成 UUID，保存和恢复保持不变 | 世界实例标识；不使用临时 NodePath 作为 ID |
| `asset_id` | 资产定义 ID | 与 AssetBase 的资源标识概念对应；当前仅固定 box |
| `owner_id` | 本机测试身份 UUID | 所有者概念；没有完整权限位、分组或身份认证 |
| `position` | 区域内位置 `[东, 北, 高]`，米 | 简化单部件物体的区域位置；尚未叠加 Grid 全局偏移 |
| `rotation` | 单位四元数 `[x,y,z,w]`，数据坐标系 | 世界旋转；UI 当前只改变绕 Z 的水平角 |
| `size` | `[X尺寸,Y尺寸,Z尺寸]`，米 | 对象尺寸；当前每轴 0.2–32 米 |
| `color` | `#RRGGBB` | 简化的整体表面颜色；无分面材质或原 TextureEntry |
| `name` | 1–80 字符 | 对象名字 |

所有变换先在数据层校验，再同步到可见网格和碰撞形状。旋转后的水平包围范围必须完全在区域内，不能只检查物体中心。

## 3. 坐标和地形

原型数据采用与本次 OpenSim 研究一致的 Z 向上约定：X 东，Y 北，Z 高。Godot 采用 Y 向上。转换由 WorldView 集中承担：

```text
数据 [x, y, z] → Godot Vector3(x, z, -y)
Godot (x, y, z) → 数据 [x, -z, y]

数据原点       [0, 0, 0]       → (0, 0, 0)
区域东北边界   [256, 256, 0]   → (256, 0, -256)
示例           [23, 91, 7.5]   → (23, 7.5, -91)
```

旋转使用基变换 `B_engine = C × B_world × inverse(C)`，不是简单交换欧拉角。已用“东向绕 Z 旋转 90 度后朝北”的用例验证。

种子地形采用 **65×65 个高程样本、4 米间距、64×64 个网格单元**，覆盖 256×256 米。高度数组索引为 `north_index * columns + east_index`，包含最东、最北边界样本。Godot 的碰撞行序朝 +Z，所以装配 HeightMapShape3D 时反转行序。采样分辨率和边缘规则与原版默认高程数组不完全相同，未来导入必须显式重采样，不能逐字节复制。

图形和碰撞共享相同样本；地面查询提供插值近似，原生碰撞仍由 Jolt 求解。斜坡上的“放到地面”按中心点查询放置，不等于完整地基拟合。

## 4. 从创建到恢复的调用链

```mermaid
flowchart LR
    UI[编辑界面 / 离线命令] --> S[WorldService 命令入口]
    S --> V[格式、归属、修订校验]
    V --> M[WorldModel 世界数据]
    M --> G[WorldView 网格与碰撞]
    M --> P[SnapshotRepository 快照]
    P --> F[主文件与有效备份]
    F --> L[校验文本摘要与数据格式]
    L --> M
```

1. 创建时先指定资产、尺寸、位置和归属，并生成实例 UUID。
2. Service 验证请求格式、当前修订及重复请求；Model 构建候选数据并做完整校验，通过后才替换内存状态。
3. WorldView 将相同实例 ID 映射到图形节点与物理形状。删除时同时移除数据与碰撞体。
4. 保存写入数据快照，不把 Godot 运行时节点、引擎指针或执行中的脚本序列化。
5. 恢复先检查存储封装、摘要和数据，再替换 Model 并重建节点；失败时不改当前世界。

OpenSim 的 `StoreObject` 明确不保存库存，另有 `StorePrimInventory`；这说明“对象存了”不等于“该对象全部状态存了”。当前原型只保存其已定义的数据范围。库存、行为状态和完整权限将在后续扩展中各自定义持久化规则。
