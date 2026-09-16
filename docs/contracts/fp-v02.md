# Fusion Protocol 0.2：V4 原版网关合同

日期：2026-09-16。实现：[FusionRegionModule](../../integration/opensim/FusionRegionModule/FusionProtocol.cs)。这是本项目对老师材料 FP-01～09 的**可执行实验子集**，尚未获得真实世界模型平台的协议确认。路径中的 `v1` 是端点代次，请求协议字段为 `fp_version="0.2"`，两者不应混用。历史 `/fusion/v0`、FP 0.1 保留用于既有行为对照。

## 1. 接口与能力边界

```text
POST http://127.0.0.1:<port>/fusion/v1/regions/<region_uuid>/commands
Authorization: Bearer <由隔离实例生成的测试令牌>
Content-Type: application/json
```

| 目标 | operation / payload | 已实现语义与限制 |
| --- | --- | --- |
| FP-01 | `WorldStateSubscribe {}` | 非附件对象组及 root Avatar 的完整帧观察；返回 `snapshot_seq`，按此游标继续读取 |
| FP-02 | `SimEventStream {after_seq,limit}` | 有界轮询，limit 1～128；组/Avatar upsert、delete、交互、动作回执及实验标记；不是全部上游事件或可靠消息总线 |
| FP-03 | `AgentSpawn {}` / `AgentDespawn {}` | 一个配置账户、一个受控 Bot 子进程；在原版观察到 Avatar 出现/消失后完成；正常退出还检查子进程退出码 |
| FP-04 | `AgentAction {action,...}` | MOVE_TO、TURN、INSPECT、INTERACT；成功根据区域末态判定，不接受后即报告完成 |
| FP-05 | `ActionReceipt {request_id,receipt_epoch}`；`CancelAction {request_id}` | 查询持久回执；移动/转向可取消；生命周期操作不可取消，受截止时间限制 |
| FP-06 | `WorldMutation {expected_seq,operation,payload}` | 静态方块和两部件组的受控操作；执行前校验观察序号及对象归属 |
| FP-07 | `AvatarSession {}` | 令牌绑定 operator、observer、secondary 三种本机测试主体；主体不可由载荷伪造；不是 SSO 或完整身份服务 |
| FP-08 | `ExperimentControl {action,experiment_id}` | start/stop 实验标记及 trace 关联；不提供训练任务、分支、暂停、确定性回放 |
| FP-09 | `TelemetryExport {}` | 同世代快照、保留事件与当前主体回执的 JSON；排除导出回执本身，避免递归嵌套；长实验需调用方逐次持久化轮询结果 |

`GetCapabilities {}` 可使用空 `world_epoch` 发现当前世代、主体权限、动作与限制。区域完整状态只指上述可见对象/Avatar 子集，不包括库存、脚本内存、资产字节、所有地形修改或全部权限字段。原型本地 API 仍使用命令封装 1，不能将 `ImportGlb(path)` 等本地命令直接发到 FP。

## 2. 请求、身份和校验

所有请求必须恰含以下 11 个字段，未知字段和重复 JSON 键被拒绝。

| 字段 | 规则 |
| --- | --- |
| `fp_version` | 字符串 `0.2` |
| `world_id`、`region_id` | 当前实例区域 UUID；首版一个世界对应一个区域，不代表最终多区域模型 |
| `request_id` | 非零、小写、带连字符 UUID；有副作用操作的稳定请求标识 |
| `trace_id` | 非零规范 UUID；由调用方关联同一实验，不承担身份认证 |
| `world_epoch` | 当前模块实例 UUID；除能力发现外必须匹配 |
| `origin` | 仅 `mock-platform` 或 `manual-test`；`opensim` 回传事件不能作为命令来源重新注入 |
| `source_seq` | 非负 64 位整数；变更操作按认证主体与 origin 严格递增 |
| `operation` | 能力声明中的操作名称 |
| `expires_at` | 带时区 ISO 8601；执行时晚于服务时间且不超过未来 60 秒 |
| `payload` | 操作定义的严格对象，不含主体、脚本代码或任意远程资源路径 |

结构合同：[请求 schema](../../integration/contracts/fp-v02-command.schema.json)、[回执 schema](../../integration/contracts/fp-v02-receipt.schema.json)、[快照 schema](../../integration/contracts/fp-v02-snapshot.schema.json)、[事件 schema](../../integration/contracts/fp-v02-event.schema.json)。[合法/非法样例](../../integration/contracts/fp-v02.examples.json) 用于结构检查，示例未来时间不是可直接执行的命令。时间窗口、UUID 与实际实例匹配、归属、四元数归一化及空间范围由运行时继续校验。

HTTP 层检查真实 loopback 对端，不信任转发头；请求上限 65,536 字节，JSON 深度 12。未知/过期令牌返回 HTTP 401，方法错误 405，长度错误 413，结构错误 400；语义拒绝一般为 HTTP 200 加明确回执。HTTP 202 表示队列尚未返回，调用方继续查询，不能视为成功。

令牌使用恒定时间字节比较，默认在模块启动 8 小时后过期，可在本机配置 `SessionExpires` 设置截止时间。operator 具有已公布操作；secondary 只能读取并修改其自身静态对象；observer 只能读取，快照与事件递归移除 `owner_id`。回执仅可由产生它的主体读取。没有用户管理、动态撤销、完整 Viewer 权限或公网 TLS 接入，适用范围为隔离本机试验。

## 3. 坐标、身份与观察序列

数据采用米、X 东/Y 北/Z 高；四元数为 `[x,y,z,w]`。Godot 坐标由适配器转换为 `(x,z,-y)`。原版组 ID 等于根部件 UUID，成员链接顺序来自 `LinkNum`；现代组 ID 独立。实体键采用 `group/<uuid>`、`part/<uuid>`、`avatar/<uuid>`，跨实现不能通过名称或组/根共用主键进行迁移。

模块每帧捕获不可变记录，对比上次观察生成 upsert/delete，事件 `seq` 在世代内单调递增。`tick` 是模块帧计数，`observed_at` 是 UTC 观察时间，均不是物理确定性时间。快照返回同一观察集合及其 `snapshot_seq`。上游物理和 Viewer 线程未被全场景锁住，因此该快照不是整个 OpenSim 内核的原子事务。

事件默认保留 2,048 条；`EventCapacity` 可配置为 32～2,048，能力声明返回实际值。游标早于保留窗口时返回 `RESYNC_REQUIRED`；调用方必须重新获取快照，再从新边界订阅。超过当前 head 或非法 limit 返回 `INVALID_CURSOR_OR_LIMIT`。重启清空内存事件并换世代，不能继续旧游标。

原版自然变化标记 `origin=opensim`、空 trace。网关动作及立即观察到的变更保留命令 origin/trace；后续物理变化不强行归因。`expected_seq` 是当前观察流 head 的乐观前置条件；它不是原版持久化修订号，也不承诺与 Viewer/物理并发修改构成全场景事务。

## 4. 动作与对象修改

| 动作 | 参数与完成条件 |
| --- | --- |
| MOVE_TO | `position:[x,y,z]`；目标在区域内、距角色不超过 32 m、高差不超过 1 m；水平距离 <0.55 m 且水平速度 <0.15 m/s 才完成；直线 steering，无路径规划 |
| TURN | `yaw`，弧度，范围 ±2π；观察到区域四元数与目标点积绝对值 >0.999 才完成 |
| INSPECT | 无附加参数；返回原版角色位置和旋转 |
| INTERACT | `group_id`；仅本人创建且带 FP 门标记的单部件；距离 ≤4 m、保守 OBB 遮挡检测通过；切换门状态与旋转并核对末态 |

抓取、冲量、任意脚本、飞行和动画返回不支持。移动碰墙会超时；不会穿墙传送以满足目标。遮挡检测按部件有向包围盒保守判定，可能把复杂空心网格判为遮挡，不声称精确网格视线。

FP-06 支持 CreateBox/CreateDoor、Link、Move、Rotate、MoveMember、Scale、Duplicate、Unlink、Delete。静态创建最多 128 部件；名称 1～64 字符；统一缩放倍数 0.25～4。组操作先检查根及归属，复制继续调用原版权限并要求对应操作者在线。原版适配器检查中心坐标及尺寸，与现代原型完整旋转占地检查不同；不代表完整地块权限、复杂 primitive 或 LSL/OSSL 语义已复制。

## 5. 调度、幂等与故障结果

HTTP 线程只校验和入队；容量 64，每帧最多处理 8 条。读、写和动作推进在区域帧回调执行。Bot 网络传输在有界子进程队列中运行，不在 HTTP 回调直接改区域。模块关闭移除端点/帧订阅并停止其管理的 Bot；不支持 DLL 在线替换，模块重启按进程冷重启验收。

状态机为 `pending → completed / failed / cancelled / result_unknown`；输入或权限拒绝为 `rejected`。失败可以保留移动的部分物理效果，取消也不撤销已走过的距离。回执带 request/trace/world/epoch、tick、event_seq 和 UTC 时间。

有副作用操作先将 prepared 回执落盘并 flush，再执行；终态以临时文件和原子替换发布。每世代最多 1,024 条变更回执，达到上限拒绝，不静默淘汰去重历史。同 request_id、主体及原始规范化内容返回原回执；改动内容或主体返回 `REQUEST_REUSED`。幂等指同世代已记录请求不重放，不是底层动作与回执文件之间的分布式事务。

冷重启后查询旧 epoch：已完成回执保持原结果；遗留 pending 返回 `result_unknown/PREVIOUS_EPOCH_INTERRUPTED`。查询缺失记录同样不能断言动作未发生。调用方应观察权威世界后决定下一步，不直接重发旧动作。回执落盘失败、内部执行异常等不伪造完成。

## 6. 实验产物与复现

[Test-Fusion.py](../../integration/opensim/Test-Fusion.py) 保存初态、事件、逐条请求/回执、遥测和摘要清单，不保存 Authorization。它是真实 OpenSim 区域的模拟平台调用端；并未连接老师设想的平台或在线大模型。

[Test-FusionRecovery.py](../../integration/opensim/Test-FusionRecovery.py) 在独占的新实例完成完整闭环、三轮 Bot 循环、事件溢出、实际 Bot/服务器进程终止、旧回执查询和过期会话测试，结束恢复测试配置并关闭其启动的进程。原版日志可能含会话标识，只保存在本地；仓库证据使用经过筛选的结构化结果。完整运行步骤见 [集成指南](../../integration/README.md)。
