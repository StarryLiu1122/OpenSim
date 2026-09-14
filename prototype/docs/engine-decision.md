# 技术选型与实现决策

适用版本：Region Lab 0.2.0。决策日期：2026-09-14。

## 1. 引擎与语言

选用 Godot 4.5.1 标准版、Compatibility 渲染器、内置 Jolt 物理和 GDScript。图形、界面、输入、场景及碰撞求解由引擎承担；世界数据、编辑规则、命令与存储由项目代码实现。

| 选择依据 | 对应需求 |
| --- | --- |
| 标准版可直接运行工程 | 降低本机安装和独立目录复现的依赖数量 |
| 图形与无界面模式共用工程 | 界面程序、数据测试、物理测试及离线命令共用实现 |
| 引擎包含场景、UI 和物理能力 | 集中验证区域编辑及角色行为 |
| GameFactory 提供 Godot 适配参考 | 参考版本化操作入口和测试分层 |

Unity 和 Unreal Engine 均可作为候选；本项目目前没有必须依赖其特定生态或资产的需求。本次未对三种引擎进行同规模性能比较。选择以当前功能范围、部署成本和验证结果为依据。[Godot 功能文档](https://docs.godotengine.org/en/4.5/about/list_of_features.html)

Godot 精确版本及发行包校验值固定于 [engine.lock.json](../engine.lock.json)。版本升级须通过当前测试集，并重新记录图形、物理和存档行为。

## 2. 语言职责

| 技术 | 当前职责 | 后续条件 |
| --- | --- | --- |
| GDScript | 原型数据服务、引擎适配、界面与测试 | 保留至出现明确的维护或性能需求 |
| C# | 原 OpenSim 数据与行为参考 | 既有服务复用或协议兼容确有收益时单独评估 |
| Python | 当前无运行依赖 | 数据库接口或模型服务立项后再引入 |
| C++ | 使用引擎已实现的原生能力 | 性能剖析确认具体计算热点后评估扩展 |

世界记录采用 JSON 可表达的数据类型，与 Godot 场景节点分离。当前领域代码仍依赖 Godot 的基础类型和运行时；跨语言复用以数据契约为边界。

## 3. 地形碰撞决策

V2 保留高度场作为持久化模型，使用相同顶点与索引生成 `ArrayMesh` 和 `ConcavePolygonShape3D`，碰撞求解仍由 Jolt 承担。高度查询采用与显示网格一致的分片线性插值。

该调整源于非共面格网测试。V1 的 HeightMapShape3D 路径在固定引擎版本下存在与显示网格不同的三角形划分，并在测试样本中产生约厘米级高度量化误差。Godot 的 Jolt 高度场适配包含行反转、镜像及高度编码处理，见 [固定版本实现](https://github.com/godotengine/godot/blob/4.5.1-stable/modules/jolt_physics/shapes/jolt_height_map_shape_3d.cpp)。V2 直接共享三角形数据，相关射线与顶点测试使用 0.002 米容差。

代价是静态三角网格的构建和碰撞成本。当前种子地形为 65×65 个顶点、8,192 个三角形，笔刷修改后整体重建地形网格和碰撞体；物体节点保留。大规模地形应进一步验证分块更新、空间索引和构建耗时。

## 4. 存储决策

V2 沿用单写入者 JSON 快照，世界与存储封装版本均为 1。新增地形命令只修改既有高度数组，故无需迁移字段。V1 样本读取、编辑及再次保存纳入兼容性测试。

数据库服务将在后续版本实施，重点包括修订事务、模式迁移、备份恢复和并发写入。当前文件指纹检查不提供跨进程锁或数据库事务语义。

## 5. GameFactory 参考范围

参考项目为 GameFactory-3A，固定提交 [378a7a733c0975cdb3b3cd924824652e6bbb66de](https://github.com/OpenDCAI/GameFactory-3A/tree/378a7a733c0975cdb3b3cd924824652e6bbb66de)。参考内容包括 [Godot 适配器](https://github.com/OpenDCAI/GameFactory-3A/tree/378a7a733c0975cdb3b3cd924824652e6bbb66de/engine_adapters/godot)、[开发流程](https://github.com/OpenDCAI/GameFactory-3A/blob/378a7a733c0975cdb3b3cd924824652e6bbb66de/agent_skills/setting_overview.md) 和 [测试组织](https://github.com/OpenDCAI/GameFactory-3A/blob/378a7a733c0975cdb3b3cd924824652e6bbb66de/agent_skills/develop_harness/README.md)。

| 参考方法 | 本项目实现 |
| --- | --- |
| 稳定的引擎操作入口 | WorldService 统一接收 UI 和离线命令 |
| 结构化执行结果 | 请求 ID、修订、结果、警告和错误分别返回 |
| 按职责封装引擎能力 | 数据模型、命令规则、场景、碰撞与存储分层 |
| 分层验收 | 数据与算法检查、原生物理、界面事件、跨进程恢复及渲染检查 |
| 面向具体功能组织开发 | 每项变更明确数据语义、修改范围、验收用例和验证记录 |

本项目未引入 GameFactory 源码、权重或生成资产，未执行其完整生成流程。当前自动化入口由确定性 JSON 样例验证，尚未集成在线大模型。
