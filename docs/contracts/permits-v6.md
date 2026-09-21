# 对象级权限合同：V6-2（FP 0.3 能力扩展）

适用：Region Lab 0.6.0（V6-2）。扩展 [FP 0.3 网络合同](network-v5.md) 第 2 节与 [身份合同 V6-1](identity-v6.md)；`fp_version` 保持 `"0.3"`。数据库 schema 5。

状态标注：**【已验证】** / **【已实现】** / **【不支持】**，同身份合同。

## 1. 模型

- `restrictions`：受限对象注册表（对象或组 UUID）。在表即默认拒绝：仅授权账户可见、可对其变更。**【已验证】**
- `grants`：`(object_id, account_id)` 授权行，记录授权者与时间。**【已验证】**
- 未受限对象保持全体可见（V5 语义）。**【已验证】**
- 授权是对世界对象的软引用；对象被删除后授权行残留但惰性，`permit list` 的 `exists` 字段标记。**【已实现】**
- 配置 `private_objects` 仅在首次启动时播种（无对应注册记录才落库），之后以数据库为准。**【已验证】**

## 2. 语义规则

| 规则 | 状态 |
| --- | --- |
| 受限对象仅授权账户在投影中可见（快照/增量一致） | 【已验证】 |
| 受限对象的未授权变更返回 `PERMISSION_DENIED`，世界修订不变 | 【已验证】 |
| 授权/收回/限制/解除在 50 ms 分发周期内对多客户端收敛（upsert/delete） | 【已验证】 |
| 执行限制的账户自动获得该对象授权（防自锁） | 【已验证】 |
| 解除限制同事务退役该对象全部授权 | 【已验证】 |
| 组内任一成员受限且未授权 → 整组（含其余成员）不投影 | 【已验证】 |
| observer 角色即使被授权也只读；不能执行任何 permit 管理 | 【已验证】 |
| 非 owner 仅可管理 `owner_id` 等于自身 `actor_id` 的对象；owner 角色可管理任意对象 | 【已验证】 |
| 授权变更后私有资产的 HTTPS 允许列表同步重算 | 【已实现】 |
| 授权与限制在权威重启后完整恢复 | 【已验证】 |

## 3. 管理接口（`type:"permit"`）

请求键恰好为 `{ fp_version, type, request_id, action, params }`；回复 `permit_result: { request_id, ok, code, data }`。

| action | params | 成功 data | 主要错误码 |
| --- | --- | --- | --- |
| `restrict` / `unrestrict` | `object_id` | `object_id`, `restricted`（幂等时附 `unchanged`） | `OBJECT_UNKNOWN`、`PERMISSION_DENIED` |
| `grant` / `revoke` | `object_id`, `account_id` | `object_id`, `account_id`, `granted` | `OBJECT_NOT_RESTRICTED`、`ACCOUNT_NOT_FOUND`、`PERMISSION_DENIED` |
| `list` | （空） | `restrictions: [{object_id, accounts[], exists}]` | — |

其他 action 返回 `UNSUPPORTED_PERMIT_ACTION`；键不齐或类型错误返回 `INVALID_PERMIT_REQUEST`。**【已验证】**

存储层对应操作：`object_restrict`、`grant_update`、`grant_list`（详见 [Store.cs](../../services/RegionStore/Store.cs)），全部写 `audit_log`（`object_restrict`/`object_unrestrict`/`grant_update`/`grant_revoke`）。**【已验证】**

## 4. 明确边界

- 无"所有权转移"接口；对象 `owner_id` 仍为领域 actor。**【不支持】**
- 惰性授权残留无自动清理。**【不支持】**（后续维护项）
- 导出包 v2 起权限表随包恢复；见 [库存合同 V6-3](inventory-v6.md) 第 4 节。**【已实现】**
- HTTPS 资产端点的 Bearer 校验仍基于配置主体；运行期新建账户的资产直取授权属 V6-3。**【不支持】**

## 5. 验证基线（2026-09-21，本机）

- `services/Test-Store.py`：100/100（含 15 项授权操作与 v4→v5 迁移回滚/重试）。
- `services/Test-Permit.cjs`：37/37（限制收敛、越权世界不变、授予/收回实时性、组语义、配置播种、重启持久、审计）。
- `services/Test-Identity.cjs`：29/29 回归。
- `services/Test-Network.cjs`：V6-1 代码两次 63/63 全绿。V6-2 代码在本机高负载时段 6 次运行中 5 次止于"六米/秒"时序用例（位移 7.1–7.2 m，界值 7 m）、1 次通过该用例后止于原生双客户端场景比对；同一时段 V5 main 对照组同样两种失败交替出现。速度上限 6 m/s 由 `move_toward(…, 6.0)` 构造保证，独立探针证实物理不变量未变；V6-2 增量不涉及移动/输入/原生客户端路径。机器空闲窗口的全绿补测列为开放项。
