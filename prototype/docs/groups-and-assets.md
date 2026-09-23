# 组合与静态网格资产规范

适用版本：0.3.1；世界格式：3；命令封装：1。

## 1. 组合记录

世界新增 `groups[]`，最多 128 组。每组有 2–100 个成员；对象总数仍不超过 500。组 ID 与成员 ID 不得冲突，根必须是成员，所有成员与组合归属一致。

```json
{
  "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "name": "建筑组合",
  "root_id": "99999999-9999-4999-8999-999999999999",
  "owner_id": "11111111-1111-4111-8111-111111111111",
  "position": [128, 140, 0.11],
  "rotation": [0, 0, 0, 1],
  "scale": 1
}
```

所有对象新增必填 `group_id`，未组合时为 `""`。未组合对象的 position、rotation、size 是世界变换；成员的相同字段是局部变换。根的局部位置为零、旋转为单位四元数，尺寸仍为部件尺寸。组位置各分量须在 -100–600 米，统一倍率在 0.1–10；最终世界尺寸、水平边界和四元数必须通过对象校验。

```text
P_world = P_group + Q_group × P_local × scale
Q_world = Q_group × Q_local
Size_world = Size_local × scale
```

局部尺寸允许 0.02–320 米作为存储中间范围，但实际投影后每轴必须为 0.2–32 米。局部位置限制为 -512–600 米。组旋转和局部旋转均要求归一化。

`GetRegionSnapshot` 返回上述原始存储结构。进程内 `WorldModel.object(id)` 返回投影后的世界变换；UpdateObject 的变换输入也使用世界坐标。外部调用者读取快照时必须根据 group_id 合成，不能将成员局部位置直接画在区域中。

## 2. 组合命令

下表列出完整 payload 字段，不接受额外字段。所有操作共用修订检查、归属检查、撤销和重做。

| 操作 | payload | 语义 |
| --- | --- | --- |
| GroupObjects | `{id,name,root_id,object_ids}` | 对 2–100 个已存在且未组合的部件建组；初始组坐标和旋转取根部件，倍率为 1 |
| UpdateGroup | `{id,patch}` | patch 非空，仅允许 name、position、rotation、scale；整组验证后提交 |
| DuplicateGroup | `{id,offset}` | offset 是区域坐标偏移，三分量 -256–256 米；新组、新成员 ID，复用资产 |
| UngroupObjects | `{id}` | 将局部变换合成世界变换，清空 group_id，保留成员 ID |
| DeleteGroup | `{id}` | 原子删除组及其所有成员 |

成功编辑通常返回 `id`、`root_id`、`changed` 与 revision；不产生变化的操作可能只返回 `changed=false` 和 revision。根部件位置与旋转只能通过 UpdateGroup 改变；其他属性仍可编辑。DeleteObject 拒绝组合成员。成员 UpdateObject 不允许修改 group_id、asset_id、owner_id 或 state。

复制单个部件的 Ctrl+D 操作创建独立对象；复制整个组合使用“组合”页的专用按钮。门灯状态属于成员，组变换不改变该状态；组副本具有独立可编辑状态。

## 3. 资产命令与记录

ImportGlb 仅允许区域所有者使用：

```json
{
  "operation": "ImportGlb",
  "payload": {
    "path": "res://../fixtures/meshes/pavilion.glb",
    "name": "示例展馆",
    "license": "CC0-1.0",
    "attribution": "Region Lab contributors"
  }
}
```

该样例是离线批处理的一项；使用 dispatch 时须另加标准协议封装。path 是当前进程可读的 `.glb` 或 `.gltf` 文件路径，不写入世界。`.gltf` 可以含 base64 数据 URI，或引用同一目录中的 BIN/PNG/JPEG 文件；拒绝 URL、子目录及上级目录引用，源 JSON 不超过 4 MiB。导入时先打包成受校验的 GLB；Web 客户端仍只选择单文件 GLB。name、license、attribution 均为 1–160 字符的非空文本；填写元数据不替代实际授权。

成功后 `payload.id` 为资产 ID。导入同一内容返回原 ID 和 `reused=true`，不增加修订，原元数据保持不变。导入只登记资产，随后使用 CreateObject 创建实例。实例 asset_id 引用该 ID，group_id 初始为空，material 必须为 plain，state 必须为 `{}`；建议颜色为 `#FFFFFF`、尺寸取资产 bounds。RemoveAsset 的 payload 为 `{id}`，仅能移除未被任何对象引用的导入资产。

| 资产字段 | 内容 |
| --- | --- |
| id | SHA256 前 128 位按 UUID 文本格式组织；完整摘要仍单独保存，不表达随机 UUID 的版本语义 |
| kind | mesh |
| uri | `embedded://sha256/<完整摘要>`，逻辑标识，不用于网络或文件解析 |
| sha256 | 打包后的 GLB 字节的 SHA256 小写十六进制 |
| name / license / attribution | 名称、许可、来源 |
| bounds | 可见包围尺寸 `[东,北,高]`，米 |
| glb | 打包后的 GLB 的 Base64 文本 |

目录前六项仍须为固定内置资产，之后最多 16 个网格资产。不同内容即使名称相同也具有独立记录。资产字段不可通过对象编辑修改。

## 4. 支持的 GLB 子集

这是项目自有的静态数据导入器，未宣称支持所有 glTF 2.0。容器与语义以 [Khronos glTF 2.0 规范](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html) 为依据；数据转换为数组，再由 [Godot ArrayMesh](https://docs.godotengine.org/en/4.5/classes/class_arraymesh.html) 构造显示与碰撞资源。

| 项目 | 支持范围 |
| --- | --- |
| 容器 | GLB 2.0，一个 JSON 块与一个 BIN 块；一个内嵌 buffer、一个场景 |
| 大小 | 单文件 ≤2 MiB；JSON 块 ≤256 KiB；世界封装序列化后 ≤8 MiB |
| 场景图 | 最多 256 节点，深度 ≤32；无循环或共享子节点；局部 TRS 或仿射矩阵烘入顶点 |
| 变换 | 有限数值、归一化四元数、正向非奇异变换；不支持镜像负缩放 |
| 几何 | TRIANGLES；POSITION float32 VEC3；可选 NORMAL float32 VEC3 与 TEXCOORD_0 float32 VEC2 |
| 索引 | 无索引或 SCALAR uint8/uint16/uint32；检查类型、偏移、对齐、步长、边界和退化面 |
| 数量 | 展开节点实例后，总顶点 ≤60,000、三角形 ≤20,000、表面 ≤64；均包含碰撞代理；单 mesh ≤32 个 primitive |
| 尺度 | 可见包围盒各轴 0.2–32 米；以米导出，导入器不猜测毫米或厘米单位 |
| 材质 | OPAQUE、baseColorFactor、metallicFactor、roughnessFactor、doubleSided |
| 贴图 | 可选内嵌 PNG/JPEG 底色、法线、金属粗糙度及遮蔽贴图，TEXCOORD_0；单图 ≤1 MiB、每轴 ≤1024 像素 |
| 采样 | repeat wrapping、linear / linear mipmap；其它显式过滤和环绕模式拒绝 |
| 不支持 | 动画、骨骼、变形目标、相机、扩展、Draco、透明、自发光贴图、顶点色；打包后的 GLB 不保留外部依赖；法线 scale 与遮蔽 strength 须为默认值 |

输入网格里的退化三角形会被跳过；若一个 primitive 因此没有有效三角形，整个资产会被拒绝。顶点与原始索引仍计入输入预算，避免用无效面绕过容量限制。

贴图 alpha 不参与透明渲染。导入后的实例颜色乘以原材质基础色。材质目前不可逐面编辑，导入实例不使用内置砖墙、木材等程序材质替换原表面。

glTF 与 Godot 都使用 Y 向上的右手坐标；导入器反转三角形绕序以符合 Godot。几何以可见包围盒中心归一化，实例尺寸恢复米制大小；原文件的自定义枢轴不保留。法线随节点变换和实例尺寸调整。不会把导入节点作为可执行场景实例化。

## 5. 碰撞与内容制作

节点名以 `COL_` 开头时，该节点及后代几何只作为碰撞代理，不显示。存在代理时，全部可见几何不再自动生成碰撞；没有代理时，使用可见三角形作为静态碰撞。代理必须位于可见包围盒内。

制作建筑时分别建立地板、墙和门楣代理，保持入口净宽和净高。制作树木时可仅提供树干代理。代理和模型均为静态凹面碰撞，不支持刚体堆叠、车辆或任意动态网格。

GLB 内节点导入后属于同一资产，不能直接在编辑器中选中单个节点。若建筑需要独立开门，应将门作为单独的内置 door 对象，再与建筑实例组合。可编辑组与 GLB 内部层级是两种不同关系。

## 6. 持久化与限制

世界格式 3 增加 groups、对象 group_id 和导入资产记录。格式 1 先经原版校验与格式 2 迁移，再增加空组合；格式 2 直接增加空组合。旧对象 ID 与变换不变，迁移在内存中完成，显式保存时才发布新格式。

保存时记录直接选择或从 glTF 打包得到的 GLB；读取时验证 Base64、完整摘要、结构与实际包围尺寸。内容不依赖原路径，移动快照后仍能重建；也没有自动下载缺失资源的行为。历史在内存中保存世界副本，因此多个较大资产会提高历史与序列化开销。8 MiB 是当前原型存档限制，后续资产仓储将另行设计。

该入口不能直接读取 OpenSim mesh asset、OAR、CAD/BIM 或无人机摄影测量包，也不执行上传、下载、任意脚本或 Godot 原生资源反序列化。
