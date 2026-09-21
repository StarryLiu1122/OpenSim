# 智能体受控接口合同：V6-4（FP 0.3 能力扩展）

适用：Region Lab 0.6.0（V6-4）。扩展 [身份合同](identity-v6.md)、[权限合同](permits-v6.md)、[库存合同](inventory-v6.md)；`fp_version` 保持 `"0.3"`。数据库 schema 7。

状态标注：**【已验证】**（测试断言过）/ **【已实现】**（代码路径存在但未单独立项断言）/ **【不支持】**（有意边界）。

## 1. agent 角色与封禁边界

- 所有者经 `account` 包创建 `role:"agent"` 账户并签发会话；欢迎包 `role` 为 `"agent"`。**【已验证】**
- agent 角色在既有通道上全部被封：

| 通道 | 行为 |
| --- | --- |
| `command`（任何世界操作） | `PERMISSION_DENIED` **【已验证】** |
| `input`（化身控制量） | 静默忽略，化身不动 **【已验证】** |
| `inventory` / `permit` 管理 / `account` 管理 | `PERMISSION_DENIED` **【已验证】** |
| 会话被撤销 / 账户被禁用 | 帧内踢出（1008），与其他角色一致 **【已实现】** |

- agent 账户与角色跨重启持久（schema 7 重建迁移）。**【已验证】**

## 2. `agent` 包

请求键恰好为 `{ fp_version, type:"agent", request_id, action, params }`（`request_id` 须 UUID，`params` 须对象）；键不齐或类型错误回 `INVALID_AGENT_REQUEST`。回复 `agent_result: { request_id, ok, code, data }`；任务状态变化另推 `agent_event: { task }`。**【已验证】**

| action | 角色 | params | 成功 data | 主要错误码 |
| --- | --- | --- | --- | --- |
| `observe` | 所有 | （空） | `state`（与快照同构的投影）, `revision`, `at_ms` | — |
| `status` | 所有 | 可选 `task_id` | `tasks[]`（仅本人任务） | `TASK_UNKNOWN` |
| `task` | 非 observer | `kind` + 种类参数 | `task`（见 §3） | `PERMISSION_DENIED`、`AGENT_TASK_UNSUPPORTED`、`INVALID_AGENT_TASK`、`AGENT_TARGET_UNKNOWN`、`AGENT_TARGET_UNSUPPORTED`、`AGENT_PATCH_FORBIDDEN`、`SERVER_BUSY` |
| `cancel` | 所有 | `task_id` | `task`（终态或 `cancelled`） | `TASK_UNKNOWN`、`INVALID_AGENT_REQUEST` |

未知 action 回 `UNSUPPORTED_AGENT_ACTION`。**【已验证】** `observe` 的投影与权限过滤和常规快照一致（受限对象不可见即不可定位）。**【已验证】**

## 3. 任务状态机与白名单

状态：`accepted → running → completed / failed / timeout / cancelled`。摘要字段：`{ task_id, kind, state, code, submitted_at_ms, finished_at_ms, detail }`。

- `move_to`：提交即 `running`；服务器每帧驱动化身（速度上限 6 m/s，由化身物理保证）。`detail.position` 为完成时世界坐标。`params: { position:[x,y,z]，可选 tolerance（0.1–5.0，缺省 0.5），可选 timeout_ms（1000–120000，缺省 30000）}`。**【已验证】**
- `set_state`：目标须可见且 `state` 含 `active`（门/灯）；其余对象回 `AGENT_TARGET_UNSUPPORTED`。`params: { object_id, active: bool }`。**【已验证】**
- `create_box`：内置立方体原始体。`params: { position，可选 name、size[3]（0.05–32）、color }`。**【已验证】**
- `update_object`：仅内置六类原始体（box/cylinder/sphere/door/tree/lamp），导入网格回 `AGENT_TARGET_UNSUPPORTED`；patch 键 ⊆ `{name, color}`，其余回 `AGENT_PATCH_FORBIDDEN`。**【已验证】**
- 世界变更类任务（后三类）进入与人工编辑相同的 CAS 命令队列（`origin:"agent"`）：取出时 `accepted→running`，CAS 冲突、过期、域校验失败都映射为 `failed` 并带域错误码。**【已验证】**（create_box 经队列完成；`failed/MUTATION_REJECTED` 路径在开发中实测出现并修复为区域行为者委托）
- 任务内变更以区域行为者执行（演示世界对象归区域所有），回执归属仍记智能体账户 id。**【已实现】**
- 超时：仅扫描 `running` 任务；`move_to` 超时即停化身。**【已验证】**
- 取消：协作式。排队中的任务连队列项一起移除；已取出执行的任务会完成落库但终态保持 `cancelled`；取消终态任务幂等返回当前状态。**【已验证】**
- 断线：放弃该客户端全部 `accepted/running` 任务（清队列、停化身、释放化身）。**【已验证】**

## 4. 明确边界

- 任务仅内存，**不持久**：重启后任务历史清空。**【已实现】**
- 无路径规划/避障：`move_to` 走直线，被碰撞体挡住会走到超时。**【不支持】**
- 无跳跃/飞行/传送、无组操作、无地形修改、无资产上传、无库存放置任务。**【不支持】**
- 任务无脚本化组合；多步编排由调用方经 `observe/status` 驱动（V6-5 验证该形态）。**【不支持】**
- 每客户端任务历史保留上限 200 条（仅淘汰终态）。**【已实现】**

## 5. 验证基线（2026-09-21，本机）

- `services/Test-Agent.cjs`：50/50（角色封禁、观察、四类任务成功/拒绝路径、超时、取消、状态查询、observer 只读、断线放弃、重启后角色持久）。
- `services/Test-Store.py`：137/137（含 schema 7 agent 角色与 v6→v7 迁移回滚）。
- 回归：`services/Test-Identity.cjs` 29/29、`services/Test-Permit.cjs` 37/37、`services/Test-Inventory.cjs` 31/31。
