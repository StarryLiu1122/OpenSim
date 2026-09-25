# 架构与接口规范

适用版本：Region Lab 0.4.2。世界格式版本：3；命令协议版本：1。

## 1. 模块职责

```mermaid
flowchart LR
    UI[编辑界面] --> S[WorldService]
    CLI[离线 JSON 命令] --> S
    S --> M[WorldModel]
    M --> V[WorldSchema / TerrainBrush]
    S --> R[RepositoryContract]
    R --> J[SnapshotRepository / JSON]
    R --> D[SqliteRepository / RegionStore]
    J --> F[快照与备份]
    D --> Q[SQLite + SHA256 内容仓储]
    M --> W[WorldView]
    W --> G[显示网格与 Jolt 碰撞]
```

| 模块 | 职责 | 主要文件 |
| --- | --- | --- |
| WorldSchema | 世界格式、字段边界、标识和完整性校验 | `godot/domain/world_schema.gd` |
| WorldTransforms / GroupCommands | 局部与世界变换、组合生命周期 | `godot/domain/world_transforms.gd`、`group_commands.gd` |
| GlbReader / MeshAssets / MeshView | GLB 校验、内容标识及静态网格投影 | `godot/adapters/` |
| TerrainBrush | 单次笔刷计算，生成候选高度场 | `godot/domain/terrain_brush.gd` |
| WorldModel | 数据副本、归属校验、原子状态替换和修订 | `godot/domain/world_model.gd` |
| WorldService | 命令封装、重复请求、历史、保存恢复 | `godot/domain/world_service.gd` |
| SnapshotRepository | 文件封装、校验、备份与发布 | `godot/adapters/snapshot_repository.gd` |
| BuiltinObjects | 六类内置对象的显示、碰撞与局部灯光 | `godot/adapters/builtin_objects.gd` |
| EnvironmentView | 太阳、天空、雾与区域水面 | `godot/adapters/environment_view.gd` |
| DemoRegion | 新建图形场景的示例数据，不改写已有存档 | `godot/domain/demo_region.gd` |
| WorldView | 坐标转换、显示网格、碰撞体与拾取 | `godot/adapters/world_view.gd` |
| Client | 物体与地形面板、角色输入和相机 | `godot/client/`、`godot/main.gd` |

世界记录不包含引擎节点。Model 在候选副本上完成校验，通过后替换状态；输入、查询和历史使用独立副本。UI 和离线工具的世界修改统一经过 Service。相机操作不修改持久化世界。

## 2. 世界格式

根字段固定为 `schema_version`、`revision`、`region`、`terrain`、`assets`、`objects`、`environment`、`groups`。

| 字段 | 约束 |
| --- | --- |
| `schema_version` | 当前为 3；格式 1/2 由专用旧版校验器验证后迁移，其它版本拒绝读取 |
| `revision` | 0–1,000,000,000 的整数 |
| `region` | `id/name/size/spawn/owner_id`；尺寸可为 256×256 或 512×512 米 |
| `terrain` | `columns/rows/spacing/heights`；覆盖范围必须与区域一致，高程 -40–80 米 |
| `assets` | 前六项为固定内置目录，之后最多 64 个内嵌 mesh 记录；完整快照仍限 8 MiB |
| `environment` | `sun_hour/water_enabled/water_height/fog_density/terrain_grid` |
| `groups` | 最多 128 组，每组 2–100 个成员；根、归属、局部与世界变换均须合法 |
| `objects` | 最多 500 个对象或组成员；ID 唯一，变换和归属须合法 |

未知字段、非有限数值、非法资产引用、未归一化旋转和越界形状均被拒绝。500 是输入上限，尚未作为已验证的性能容量。

坐标、字段及 OpenSim 对应关系见 [数据模型说明](opensim-data-mapping.md)。V3 对象增加 `material` 和 `state` 必填字段。应用版本、世界格式和命令封装版本分别管理；命令封装仍为 1，但 CreateObject 必须提交格式 3 对象，group_id 初始为空字符串，不能省略新增字段。

## 3. 命令封装

进程内入口为 `WorldService.dispatch(command)`：

```json
{
  "api_version": 1,
  "request_id": "66666666-6666-4666-8666-666666666666",
  "operation": "SculptTerrain",
  "expected_revision": 0,
  "payload": {
    "mode": "raise",
    "center": [116, 140],
    "radius": 12,
    "strength": 0.5,
    "target_height": 5
  }
}
```

`expected_revision` 必须与当前修订一致，包括查询操作。进程内便捷方法 `request(operation, payload)` 自动提供新请求 ID 和当前修订。当前没有网络传输、认证或远程查询握手。

| 操作 | payload | 结果或状态变化 |
| --- | --- | --- |
| `GetRegionSnapshot` | `{}` | 返回 `payload.world` 独立副本 |
| `CreateObject` | `{"object": 完整物体}` | 创建物体，校验归属、资产及变换 |
| `UpdateObject` | `{"id": "UUID", "patch": 修改字段}` | 可改 name、position、rotation、size、color、material |
| `DeleteObject` | `{"id": "UUID"}` | 删除当前身份拥有的未组合物体 |
| `SculptTerrain` | 笔刷参数，见下节 | 修改区域归属允许的高度场 |
| `UpdateEnvironment` | `{"patch": 修改字段}` | 区域所有者更新环境；拒绝空 patch 和未知字段 |
| `SetObjectState` | `{"id": "UUID", "active": true}` | 物体所有者设置门/灯状态；只接受 boolean |
| `Undo` | `{}` | 撤销最近一次有效编辑 |
| `Redo` | `{}` | 重做最近撤销的编辑 |
| `SaveRegion` | `{}` | 保存当前世界，成功后清除未保存标记 |
| `LoadRegion` | `{}` | 验证并恢复世界，清空历史及请求缓存 |

完整物体样例见 [create-and-save.commands.json](../fixtures/create-and-save.commands.json)。复制和地面放置由客户端组织为创建或修改命令，不单设持久化操作。

结果字段固定为：

```json
{
  "api_version": 1,
  "ok": false,
  "operation": "SculptTerrain",
  "request_id": "66666666-6666-4666-8666-666666666666",
  "revision": 1,
  "payload": {},
  "warnings": [],
  "errors": [{"code": "REVISION_CONFLICT", "message": "World changed; query the current revision and retry."}]
}
```

常见错误代码为 `INVALID_COMMAND`、`INVALID_PAYLOAD`、`REQUEST_REUSED`、`REVISION_CONFLICT`、`MUTATION_REJECTED`、`IMPORT_REJECTED`、`SAVE_FAILED`、`LOAD_FAILED`、`NOTHING_TO_UNDO`、`NOTHING_TO_REDO`、`HISTORY_REJECTED` 和 `UNKNOWN_OPERATION`。详细校验原因通过 `message` 返回。

## 4. 地形笔刷契约

`SculptTerrain` 必须包含以下五个字段：

| 字段 | 范围与含义 |
| --- | --- |
| `mode` | `raise`、`lower`、`flatten`、`smooth` |
| `center` | `[X,Y]`，各分量 0–256 米 |
| `radius` | 4–32 米 |
| `strength` | 0.05–1.0，UI 显示为百分比 |
| `target_height` | -40–80 米；仅 flatten 使用，其它模式保留字段但不使用 |

对半径内采样点，设距中心距离为 `d`，半径为 `r`，强度为 `s`：

```text
t = 1 - d / r
w = s × t² × (3 - 2t)
raise:   h' = h + 8w
lower:   h' = h - 8w
flatten: h' = (1-w)h + w × target_height
smooth:  h' = (1-w)h + w × mean(neighborhood_3x3)
```

`d >= r` 的采样不参与修改。平滑读取操作开始前的高度数组，区域边缘仅取有效邻点。结果限制在高程范围内并取毫米精度；变化小于或等于 0.0005 米时保留原值。

一次调用对应一次笔刷印迹。成功结果中 `changed_samples` 为修改点数；无有效变化时 `changed=false`，修订、历史和未保存状态保持不变。超出区域的笔刷覆盖范围被裁切，笔刷中心本身必须在区域内。

## 5. 历史、修订与重复请求

- 有效物体、地形、环境、行为、组合或资产编辑增加修订，并记录修改前的世界；历史上限为 30 次。
- 撤销和重做均使用新的修订值。新有效编辑清空重做分支；通过校验的无变化操作保留该分支。
- 保存不清除历史。恢复存档清空两个历史栈，并使用存档中的修订；该值可能小于恢复前的内存值。
- 修订达到上限时，新增编辑及历史操作返回错误，保持数据和历史不变。
- Service 缓存最近 256 个请求。同一 ID 与相同内容返回原结果，ID 相同但内容不同返回 `REQUEST_REUSED`。
- 缓存及历史不跨进程持久化。后续多人系统需要另外定义世界世代、服务端排序、身份认证与持久化去重。

当前身份为固定本机测试 UUID。归属校验验证编辑规则，不提供远程访问认证。

### 5.1 V3 环境与行为契约

| 环境字段 | 类型与范围 |
| --- | --- |
| sun_hour | 有限数值 0–24，固定示意太阳时刻 |
| water_enabled | boolean |
| water_height | 有限数值 -40–80 米 |
| fog_density | 有限数值 0–0.02 |
| terrain_grid | boolean |

物体 material 为 plain、concrete、brick、wood 或 metal。state 在 door、lamp 上必须为 `{"active": boolean}`，其它类型必须为 `{}`。active=true 对应开门或开灯。UpdateObject 不能修改 asset_id、owner_id 或 state，行为状态只能通过 SetObjectState 变更。非交互资产拒绝行为命令。

漫游的 4 米距离和遮挡检查位于客户端拾取层，射线同时检测地形与物体。编辑面板和离线工具允许设置当前身份拥有的任意门灯；这不是服务端距离权限机制。交互只切换有限内置状态，不执行脚本文本。

## 6. 地形场景同步

高度场生成共享顶点与索引，显示使用 ArrayMesh，静态碰撞使用 `create_trimesh_shape()` 生成的 ConcavePolygonShape3D。每个格网沿“东南—西北”对角线分为两个三角形；地面查询在对应三角形内作线性插值。

地形变更重建地形显示与碰撞节点，保留物体节点。角色低于新地面时抬至地面上方；恢复时按区域起点和地面高度确定角色位置。物体不会随地形自动移动。

种子地形有 8,192 个三角形。目前采用整块重建，尚无局部块更新和容量优化。选择依据见 [技术选型](engine-decision.md)。

### 6.1 对象与环境投影

WorldView 保留稳定 ID 到 StaticBody3D 的映射。对象记录改变时更新该物体的几何和碰撞，不重建整个世界。BuiltinObjects 生成方块、圆柱、球和复合门、树、灯。圆柱和球采用烘入非均匀尺寸的凸碰撞；树木只有树干碰撞，叶冠用于显示。树干和门框使用固定内置配色，主表面使用记录颜色，树冠使用专用叶片着色。

门的两侧伸缩面板在打开时收回到门框范围内，中央碰撞随状态变化；没有连续动画。所有部件均保持在对象声明的尺寸范围内，复合引擎节点不等价于可编辑的 OpenSim linkset。

EnvironmentView 根据持久化参数设置天空、太阳、雾及 256×256 米水面。太阳时刻固定，水面只做渲染；两者都不是真实天气或水动力模拟。地形网格、地面查询与碰撞的共同三角形规则不变。

## 7. 存储协议

磁盘封装含 `format="region-lab.snapshot"`、`version=1`、`sha256`、`world_json`。`world_json` 是完整世界的 JSON 文本字符串；SHA256 针对该字符串的 UTF-8 文本计算，验证后再解析世界。

保存顺序为：验证数据 → 写临时文件 → flush 并关闭 → 回读验证 → 更新有效备份 → 替换主文件。损坏主文件不会覆盖有效备份。主文件读取失败时尝试备份；备份恢复返回警告并标记为需要保存。两份文件都无效时不替换内存世界。

格式 1 的载荷通过 LegacyWorldSchema 完整验证后，在副本上补入默认环境、material=plain、state={} 并替换为内置目录。ID、地形、区域和修订保留。LoadRegion 返回 migrated=true，设置 dirty=true；读取不改写原文件。随后补入 groups=[]、group_id=""；格式 2 则直接补入组合字段。下一次显式保存发布格式 3，并将有效原文件轮换为备份。

快照上限 8 MiB。文件摘要用于损坏检测，不是身份签名。写入前文件指纹可发现已经发生的外部修改，但检查和发布之间没有跨进程锁。断电持久性、多人事务和数据库迁移尚未验证。

## 8. 离线批处理

`godot/tools/world_cli.gd` 接受显式的世界、命令和报告路径。命令文件为最多 1 MiB、1–100 项的 JSON 数组，每项仅含 `operation` 和 `payload`。适配器调用 Service 的便捷入口，自动填充本次进程的请求 ID 与修订。

命令按序执行，首个失败即停止并退出 1；全部成功退出 0。只有显式 `SaveRegion` 才写入世界文件。批处理不是事务，先前已经完成的保存不会因后续失败而回滚。输入、世界及其临时/备份路径不能用作报告输出路径。

新文件的离线命令服务使用八个方块的基础数据集；图形程序新建世界使用 DemoRegion 的展馆场景。两者采用同一格式和命令规则，已存在文件均优先加载存档。

样例包括 [环境与开门](../fixtures/environment-and-door.commands.json)、[物体创建](../fixtures/create-and-save.commands.json) 与 [地形编辑、撤销重做及保存](../fixtures/sculpt-and-save.commands.json)。自动化入口接收限定的数据命令，不执行调用方传入的脚本文本或原生资源。


## 9. 固定资产目录

| kind | UUID | uri |
| --- | --- | --- |
| box | 22222222-2222-4222-8222-222222222222 | builtin://unit-box |
| cylinder | 22222222-2222-4222-8222-000000000002 | builtin://unit-cylinder |
| sphere | 22222222-2222-4222-8222-000000000003 | builtin://unit-sphere |
| door | 22222222-2222-4222-8222-000000000004 | builtin://unit-door |
| tree | 22222222-2222-4222-8222-000000000005 | builtin://unit-tree |
| lamp | 22222222-2222-4222-8222-000000000006 | builtin://unit-lamp |

上表是目录前六项的内置工厂白名单；后续 mesh 条目存放经校验的 GLB 字节，内置 uri 不用于任意文件加载。树木、门和灯内部使用多个引擎节点，但仍对应一个对象 ID。

## 10. V3.1 扩展

新增 GroupObjects、UpdateGroup、DuplicateGroup、UngroupObjects、DeleteGroup、ImportGlb、RemoveAsset。完整字段和支持边界见 [组合与资产规范](groups-and-assets.md)。这些操作均经过 WorldService，不存在第二条只修改场景节点的持久化编辑路径。RegisterAsset 是 Model 内部操作，不对命令调用方开放。

WorldView 先解析组变换再投影到引擎坐标，未改变的对象保留其 StaticBody3D。导入器产出数据数组，不实例化文件中的节点；MeshView 生成 ArrayMesh、StandardMaterial3D 与静态三角碰撞。快照的 GLB 内容按摘要缓存解析结果，但缓存不是存档的必要依赖。

应用层数据记录仍不含 Godot Node 引用。当前实现使用 GDScript 数学类型进行运行时计算，并在世界校验时调用格式适配器；这不是已经可直接替换为任意语言的服务端库。后续服务拆分应先固定契约与测试，再迁移执行实现。

## V4 仓储扩展

WorldService 构造函数可注入实现 repository_contract.gd 的仓储，默认仍为 SnapshotRepository。SQLite 适配器维护独立的 commit_revision 和待确认 request_id，通过本机受控 CLI 校验并提交完整候选；失败不清除 dirty。数据库存在但缺少该区域时可新建，损坏或不可读数据库必须进入明确错误路径，不能悄悄变成新世界。

世界内部 revision、数据库 commit_revision、恢复 epoch 和 FP event_seq 各自独立。命令封装 1 的进程内幂等缓存没有变成远程持久去重；后者由 RegionStore/FP 各自合同承担。具体 SQL、文件发布顺序、包限额、迁移与错误语义见 [存储合同](../../docs/contracts/storage-v4.md)，原版网络接口见 [FP 0.2](../../docs/contracts/fp-v02.md)。

## V5 网络运行补充

网络入口位于 "godot/network"，由独立权威 WorldService、SQLite 提交工作线程、只读 LocalWorldView、桌面/Web 客户端及 HTTPS 资产加载器组成。原离线 WorldService 与批处理入口保留。网络不接受 SaveRegion、LoadRegion 或完整世界替换；变更确认、epoch/revision/seq、会话和 AOI 合同见 [FP 0.3](../../docs/contracts/network-v5.md)，启动见 [网络指南](network-quickstart.md)。

角色为会话瞬态数据；场景和门灯在数据库持久化。世界格式 3、领域封装 1 不变，SQLite schema 升为 3。网络成功回执与世界事务原子提交；备份包仍只导出世界和资产，不复制认证配置或历史回执。
