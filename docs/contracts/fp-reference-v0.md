# FP 原版参考适配合同 v0

日期：2026-09-16。状态：可运行的**实验子集**，`fp_version="0.1"`，端点使用 `/fusion/v0`。这是项目侧合同；老师材料中的 FP-01～09 为目标接口，不代表真实平台已经确认本实现。

## 1. 与九类目标接口的关系

| 目标接口 | 本轮输入或输出 | 当前交付边界 | 后续验收 |
| --- | --- | --- | --- |
| FP-01 WorldStateSubscribe | GetCapabilities、GetSnapshot | 固定操作者的对象和 Avatar 全量观察 | 增量、删除、快照边界、重订阅、可见范围 |
| FP-02 SimEventStream | 暂无事件端点 | `event_stream=false`；审计记录不是世界事件流 | 实际原版事件采集、来源与顺序、断线补齐 |
| FP-03 AgentSpawn/Despawn | 独立 ReferenceBot 登录/退出工具 | 真实原版协议连接可复现，未包装为远程生命周期命令 | 受控账户创建、状态机、清理、重复调用 |
| FP-04 AgentAction | Bot 工具的短时前进与转向 | 区域末态可读取，未实现 MOVE_TO 或导航 | 目标到达、距离/遮挡、取消、不可达与超时 |
| FP-05 ActionReceipt | 参考端点请求回执和 GetReceipt | 静态操作的完成/拒绝/未知结果；同世代幂等 | 异步动作、持久回执、故障恢复 |
| FP-06 WorldMutation | CreateBox、Link、Move、Rotate、MoveMember、Scale、Duplicate、Unlink、Delete | 固定区域操作者、受限静态两部件测试 | 候选校验、统一权限、前置修订、冲突、来源 |
| FP-07 AvatarSession | 本机测试令牌绑定配置 Owner | 真实对端 loopback 校验；不接受载荷主体 | 多主体、能力令牌、会话撤销、SSO |
| FP-08 ExperimentControl | 测试脚本分阶段运行与正常重启 | 命令、回执、阶段初态/末态形成证据 | 创建/启动/暂停/分支/回放/终止合同 |
| FP-09 TelemetryExport | JSON 检查与对照报告、元数据审计 | 离线可解析、可再分发的脱敏证据 | 遥测流、指标定义、完整实验导出包 |

后续公共 FP 必须包含 `world_id/region_id/source_runtime/origin`、主体可见范围、实体映射、时钟和版本等字段。本轮没有用 `adapter_sequence` 冒充世界修订或完整事件序号；因此 V4.0-06 与 V4.1 整体仍处于未验收状态。

## 2. 传输与请求

```text
POST http://127.0.0.1:<port>/fusion/v0/regions/<region_uuid>/commands
Authorization: Bearer <private generated token>
Content-Type: application/json
```

先用空 `world_epoch` 请求 GetCapabilities，读取返回世代。随后所有请求使用该世代。请求均包含以下七个字段，拒绝额外字段与重复 JSON 属性：

| 字段 | 约束 |
| --- | --- |
| fp_version | 固定字符串 `0.1`，独立于 Godot `api_version=1` |
| request_id | 非零、小写、标准连字符 UUID |
| trace_id | 同一操作链可复用的非零小写 UUID |
| world_epoch | 能力发现时可为空；其余必须等于本次模块实例的 UUID |
| operation | 能力声明中列出的操作 |
| expires_at | 带时区的 ISO 8601 时间；执行时应处于当前时刻至未来 60 秒内 |
| payload | 操作规定的对象，字段严格匹配 |

处理器限制请求体 65,536 字节、JSON 深度 12、等候队列 64 条，每帧最多处理 8 条。5 秒未得到执行结果时，HTTP 202 返回 `pending/QUERY_RECEIPT`；请求仍可能排队，调用者按原 ID 查询结果。这个处理器限制不构成原版 HTTP 服务器的负载或防攻击能力保证。

[JSON Schema](../../integration/contracts/reference-command.schema.json) 和 [28 个合法/非法样例](../../integration/contracts/reference-command.examples.json) 定义结构。静态样例中的时间、ID 和世代不能直接用于运行区域；校验程序见 [Test-Contracts.ps1](../../integration/contracts/Test-Contracts.ps1)。四元数归一化、对象存在性、权限、区域边界和截止时间的有效性属于运行语义检查。

## 3. 操作载荷

| 操作 | payload | 结果或限制 |
| --- | --- | --- |
| GetCapabilities | `{}` | 操作白名单、所有者、限制和明确的不支持项 |
| GetSnapshot | `{}` | 所有者的非附件对象组、部件世界/局部变换及所有者 Avatar |
| GetReceipt | `{request_id}` | 当前世代中指定修改请求的原回执；未找到不等于未执行 |
| CreateBox | `{name,position,size}` | 名称 1～64 字符；创建当前所有者的静态立方体 |
| Link | `{root_id,child_id}` | 两个不同的独立部件；指定根，调用原版 LinkObjects |
| Move | `{group_id,position}` | 原版组世界位置 |
| Rotate | `{group_id,rotation}` | XYZW 归一化四元数；绕区域 Z 正向旋转使东转向北 |
| MoveMember | `{group_id,member_id,local_position}` | 编辑已链接子部件的原版局部偏移；不接受根 |
| Scale | `{group_id,factor}` | 相对当前尺寸的统一倍率，0.25～4 |
| Duplicate | `{group_id,offset}` | 世界偏移；需要操作者在线且通过原版复制权限 |
| Unlink | `{group_id}` | 当前仅两部件；调用原版 DelinkFromGroup |
| Delete | `{group_id}` | 删除指定所有者对象组 |
| Backup | `{}` | 请求原版 Backup(true)，不直接宣称磁盘持久性完成 |

向量使用区域 X 东、Y 北、Z 高，单位米。试验操作检查各部件**中心**在 X/Y 1～255、Z 0.5～100 米范围；每轴尺寸 0.1～16 米。它不是完整旋转包围体边界校验，和 Region Lab 的对象占地校验范围不同。创建和复制后原版区域最多 128 个部件。

原版缩放会直接修改部件偏移和尺寸；Region Lab 保留独立组倍率。两边字段不能直接复制，须先合成世界变换再映射。该适配器的命令名也不等于原型 WorldService 的命令名。

## 4. 调度、回执与幂等

HTTP 线程只读取和验证封装，并将请求排队。场景读写在该区域 `OnFrame` 回调中执行。原版自身的 Viewer、物理和模块仍有各自线程；本实现没有给原版全场景建立事务锁，也不承诺所有外部变化与快照构成原子边界。

回执字段为 `fp_version/request_id/trace_id/world_epoch/operation/state/error/tick/adapter_sequence/data`。

| 状态 | 含义 | 调用者行为 |
| --- | --- | --- |
| pending | HTTP 等候结束，当前请求可能仍在队列中 | 使用相同世代和请求 ID 查询，不能用新 ID 盲目重发 |
| completed | 同步参考操作完成，data 保存对应结果 | 静态变换可立即观察；Backup 另需跨进程验证 |
| rejected | 明确未接受该操作或运行约束未满足 | 依据错误修正输入；不要把拒绝当成成功 |
| result_unknown | 执行或审计失败，无法保证副作用结果 | 读取权威状态并人工/上层协调，不自动重放 |

`tick` 是模块收到的帧回调计数，不是物理步数或 UTC。`adapter_sequence` 统计本模块成功的修改调用，包括备份请求；原版 Viewer 和物理引起的变化不会递增它。因此它不能用于 CAS、世界增量、丢包判断或不同模块之间排序。

每个世代最多缓存 1,024 个修改请求，不淘汰旧回执后再接受重放。相同 ID、相同规范化内容返回旧结果；相同 ID、不同内容返回 REQUEST_REUSED。规范化排序对象键，但保留数字的 JSON 表达；`1` 与 `1.0` 可被判为不同请求。重启生成新世代，旧世代修改返回 EPOCH_MISMATCH。

修改执行前写入并 flush 一条 prepared 审计，完成后写入 terminal 元数据；审计不记录密码、令牌或完整请求载荷。回执缓存不跨进程恢复，审计也不是可自动重放的日志。prepared 无终态的请求，在重启后必须按结果未知处理。模块重启、排队取消、断线恢复和审计/磁盘失败尚未完成系统性故障验证。

## 5. 拒绝与实际证据

HTTP 层使用 401（对端/凭据）、405（方法）、413（处理器请求体限制）、400（封装/JSON）。已经进入调度的语义错误保留 HTTP 200，并通过 `state/error` 表达。不能只判断 HTTP 200 就记录成功。

实际测试覆盖非法变换、错误根、重复成员、未知操作、过期命令、旧世代、重复请求、错误令牌、未知封装字段、主体伪造、空向量、畸形 JSON、重复属性与请求体上限。全部数据见 [对照记录](../comparisons/v4-reference-linkset.md)。跨归属原版对象、会话吊销、队列耗尽和权限边界的完整矩阵留待 V4.1。

## 6. 进入正式 FP 的条件

先修复并锁定 .NET 8 兼容的 Bot 库，再实现独立账户、能力限制、生命周期和动作状态机。状态与事件需要明确的源序号、快照边界和恢复协议；修改需要前置修订、候选校验与可追踪结果。真实平台给出端点、认证和 schema 后，另建正式适配并执行联合测试，保留本参考端点作为固定对照工具。
