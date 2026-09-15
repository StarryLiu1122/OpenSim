# V4 固定原版与 Region Lab 两部件运行对照

日期：2026-09-16。结论：**固定 OpenSim 已独立构建和运行；本轮静态两部件案例的世界位姿、复制、解除与正常重启恢复通过对照。** 这是 V4 首批工程证据，完整权限、Viewer、Web、真实建筑和数据库任务仍未验收。

## 1. 固定输入与方法

| 项目 | 实际输入 |
| --- | --- |
| 原版源 | OpenSimulator 提交 `1f4a6dd1d3ff653ecc2748a7764106c30ac4ef9d`，导入树 `fbf3a3c632b08e6d90a3afd519e9577fa20eb695` |
| 构建 | .NET SDK 8.0.424、net8.0、Release，0 警告/0 错误；在全新含空格目录执行构建脚本 |
| 运行 | Windows 11 x64；.NET 8.0.30；OpenSim 0.9.3.0 Nessie Release |
| 原版区域 | 256×256 米；位置 1000,1000；独立区域 UUID；19110 测试端口；平地；BulletSim；YEngine；原版 SQLite |
| 原型 | Region Lab 0.3.1，世界格式 3；Godot 4.5.1 标准版；Jolt；全部修改经过 WorldService |
| 观察 | 原版独立区域模块读取实际 SceneObjectGroup/SceneObjectPart/ScenePresence；原型读取世界模型并合成变换 |
| 客户端 | ReferenceBot 0.4.0-dev 与固定 OpenMetaverse 库；未使用图形 Viewer，Viewer 显示一致性尚未验证 |
| 比较 | 按测试部件名称和世界位置配对；位置、尺寸、XYZW 四元数逐分量容差 0.0002 |

原版操作进入区域 OnFrame 回调后调用原版建组、变换、复制和解除方法。没有用预制 JSON 充当原版输出。原型同一案例跨三个独立 Godot 进程执行；两个原版保存节点均经过 `shutdown`、进程退出、重新启动后读取。

新区域、账户、密码、令牌和存储与用户世界隔离。原始日志可能包含登录会话信息，提交材料仅含测试对象数据、脱敏摘要及启动/关闭白名单摘录。完整复现步骤见 [集成工具说明](../../integration/README.md)。

## 2. 实际检查结果

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| 原版源构建 | 成功，0 警告、0 错误 | [build.json](evidence/v4-reference-20260916/build.json)、[依赖摘要](evidence/v4-reference-20260916/dependencies.json) |
| 原版创建与异常序列 | 52 项通过 | [opensim-Create.json](evidence/v4-reference-20260916/opensim-Create.json) |
| 原版组恢复、解除 | 17 项通过 | [opensim-RestartLinked.json](evidence/v4-reference-20260916/opensim-RestartLinked.json) |
| 原版解除后再恢复 | 12 项通过 | [opensim-RestartUnlinked.json](evidence/v4-reference-20260916/opensim-RestartUnlinked.json) |
| 原型同一案例 | 31+6+3，共 40 项通过 | [创建](evidence/v4-reference-20260916/godot-Create.json)、[组恢复](evidence/v4-reference-20260916/godot-RestartLinked.json)、[解除后恢复](evidence/v4-reference-20260916/godot-RestartUnlinked.json) |
| 跨实现逐项比较 | 130 项通过 | [transform-comparison.json](evidence/v4-reference-20260916/transform-comparison.json) |
| 接口结构样例 | 28 项通过 | [contracts.json](evidence/v4-reference-20260916/contracts.json) |
| 额外实际 HTTP 拒绝 | 12 项通过 | [protocol.json](evidence/v4-reference-20260916/protocol.json) |
| 原版 Bot | 登录、有界前进、朝北转向、区域确认退出 | [bot.json](evidence/v4-reference-20260916/bot.json) |
| 既有原型回归 | 原生 188/188；两类跨进程恢复、三组离线批处理通过 | [原生报告](evidence/v4-reference-20260916/native-regression.json)、[执行摘要](evidence/v4-reference-20260916/run-summary.json) |

数量为脚本断言与数据字段检查数，包含接口完成检查和不同阶段的重复状态核对，不代表相同数量的独立功能。188 项原型原生检查不能替代原版运行证据；本次未重跑 66 项 UI 检查，界面历史证据仍归属 V3.1。

## 3. C01～C09 观察

| 案例 | 操作与预期 | 实际结果 | 判定 |
| --- | --- | --- | --- |
| C01 | 两个 1 米部件，根 `[120,128,2]`、子 `[122,128,2]` | 两端均为两个独立物体；记录各自 UUID 与归属 | 位姿一致，记录组织不同 |
| C02 | 显式选择根并建组 | 子世界位置不变，局部偏移 `[2,0,0]`；原版根 LinkNum=1、子=2 | 核心行为一致；组身份规则不同 |
| C03 | 组移到 `[123,132,2]` | 子到达 `[125,132,2]`，相对关系保持 | 一致 |
| C04 | 恢复根初始位置后绕 Z 正向 90° | 子到达 `[120,130,2]`；东转向北 | 一致 |
| C05 | 子局部偏移设为 `[3,0,0]`，随后统一放大 2 倍 | 子世界位置 `[120,134,2]`、尺寸 `[2,2,2]` | 世界变换一致；缩放存储不同 |
| C06 | 世界偏移 `[10,0,0]` 复制 | 新组/成员身份，副本根 `[130,128,2]`、子 `[130,134,2]`；方向保持 | 静态副本行为一致 |
| C07 | 保存、正常退出、重启 | 两组、四部件、原 ID、局部/世界变换及尺寸保留 | 一致 |
| C08 | 解除原组合，再保存和重启 | 原根/子 ID 与世界位姿保留，副本不受影响 | 一致；组集合表示不同 |
| C09 | 越界、无效四元数、重复成员、错误根、零缩放等 | 已列非法操作拒绝，原世界不变 | 本子集通过；原版跨归属与细粒度权限未验收 |

原型子部件 UpdateObject 接受世界位置，因此 C05 输入 `[120,131,2]`；原版 UpdateSinglePosition 使用子局部偏移，输入 `[3,0,0]`。两边在操作适配处转换语义，没有用同名字段强行表达同一空间。

## 4. 必须保留的数据差异

| 项目 | OpenSim 0.9.3.0 实际记录 | Region Lab 格式 3 | 后续映射 |
| --- | --- | --- | --- |
| 组身份 | group UUID 等于根部件 UUID | 独立 group UUID，不能与成员冲突 | 显式区分源组 ID、源根 ID 与现代组 ID |
| 独立物体 | 仍由一个单部件 SceneObjectGroup 表达 | `objects[].group_id=""`，没有单部件组记录 | 不按两边组数量直接判等 |
| 根旋转 | 根 RotationOffset 为组世界旋转 | 根局部旋转为单位四元数，组另存世界旋转 | 原版根字段不能直接写入现代局部旋转 |
| 统一缩放 | 直接改写 Scale 和子 OffsetPosition；C05 子偏移为 6 米 | 组 scale=2，子局部偏移仍为 3 米、局部尺寸为 1 米 | 先合成世界空间，再选择目标存储表达 |
| 编辑根 | 原版具有单独调整根且保持其他部件的内部路径 | 原型要求通过 UpdateGroup 改变根位姿 | 此类编辑不在本轮等价范围 |
| 边界与权限 | 原版规则及当前参考适配器限制 | 原型整体候选校验、旋转占地与固定 owner | 分别记录允许范围，不声称完整兼容 |

本次全部部件为静态盒体，未比较原版资产编码、脚本库存、任务库存、权限位传播、材料或动态物理。YEngine 已实际启动，但未运行 LSL 对照脚本。Jolt 与 BulletSim 的运动轨迹、浮点行为和性能也没有据此建立等价保证。

## 5. Bot 观察和已知兼容性问题

最终 Bot 报告记录：从区域位置约 `[100,100,1.0532]` 开始，发送两秒前进后到达约 `[105.4820,99.9996,1.0900]`，朝北转向后的区域四元数约 `[0,0,0.7071,0.7071]`；退出后区域 Avatar 列表为空。实际距离约 5.48 米，由区域回报确认。该场景没有导航目标到达、绕障或长时间运行验收。

固定 OpenMetaverse 库在退出异步回调中调用 `Thread.Abort`，.NET 8 会记录 `PlatformNotSupportedException`。本次角色已从区域移除，程序返回成功；该日志保留为已知兼容性缺陷，不能宣称 Bot 客户端完全正常。V4.1 前需要固定可复现的兼容修复及版本，再测试循环登录退出、断线和清理。

初次接入曾因日志组件缺少 ConfigurationManager 依赖失败，现已补齐固定原版组件引用。尝试以客户端位置追踪三米目标时发生过超时；最终工具明确缩小为短时运动及区域末态确认，没有把该失败改写为导航通过。

## 6. 证据与复现范围

证据文件清单及 SHA256 见 [manifest.json](evidence/v4-reference-20260916/manifest.json)。[生命周期摘录](evidence/v4-reference-20260916/lifecycle-excerpts.txt) 仅保留版本、对象加载数、持久化和正常退出消息，省略登录会话、系统路径和其余日志。测试命令保留随机对象和 trace UUID，不包含账户密码或令牌。

本轮已验证同机独立目录、真实协议连接与正常进程重启；没有进行断电、崩溃恢复、低端硬件、跨平台、图形 Viewer 或互联网部署测试。完整剩余任务见 [V4 执行记录](../plans/v4-progress.md)。
