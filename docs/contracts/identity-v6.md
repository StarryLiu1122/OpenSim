# 身份与会话合同：V6-1（FP 0.3 能力扩展）

适用：Region Lab 0.6.0（V6-1）。本合同扩展 [FP 0.3 网络合同](network-v5.md)，不改变其会话、快照、增量、命令与回执语义；`fp_version` 保持 `"0.3"`。世界格式 3、数据库 schema 4。

状态标注：**【已验证】**= 自动化测试覆盖；**【已实现】**= 代码路径存在但未单独断言；**【不支持】**= 明确拒绝或缺失。

## 1. 数据模型（SQLite schema 4）

| 表 | 字段与约束 |
| --- | --- |
| `accounts` | `id` UUID 主键；`name` 1–64 字符且唯一；`actor_id` UUID；`role ∈ {owner, editor, observer}`；`disabled ∈ {0,1}`；创建/更新毫秒时间 |
| `sessions` | `token_hash`（SHA-256，64 位小写十六进制）主键；`account_id` 外键级联；`issued_at_ms < expires_at_ms`；`revoked ∈ {0,1}`、`revoked_at_ms` |
| `audit_log` | 只追加：`at_ms`、`account_id`（可空）、`action`、`outcome`、`detail ≤ 2048` |

- 明文令牌**只**在签发响应中出现一次；库中、目录接口、审计只出现哈希。**【已验证】**
- 会话 TTL 限 60 秒～30 天；到期判断以权威服务器 UTC 毫秒为准。**【已验证】**
- v3→v4 迁移单事务执行；注入故障整体回滚 DDL 与版本号，可重试。**【已验证】**

## 2. 引导与认证

- 启动时把 `config.principals` 幂等落库：已有会话跳过；无可用 owner 时首个配置主体提升为 owner。**【已验证】**
- 已过期的配置令牌不落库，认证返回 `AUTH_FAILED`；未到期者按剩余有效期转为会话（钳制到 TTL 边界）。**【已验证】**
- `hello` 认证链：令牌 → SHA-256 → 会话（存在/未撤销/未到期）→ 账户（存在/未禁用）。失败关闭 1008。**【已验证】**
- 在线连接的存活检查每帧执行：会话被撤销或账户被禁用 → 1008/`SESSION_REVOKED`；会话到期或连接满八小时 → 1008/`SESSION_EXPIRED`。RegionHost 转发关闭状态码与原因。**【已验证】**

## 3. 管理接口（`type:"account"`）

请求：`{ "fp_version":"0.3", "type":"account", "request_id":<UUID>, "action":<字符串>, "params":<对象> }`，键必须恰好为这些。回复 `account_result`：`{ request_id, ok, code, data }`。**仅 owner 角色可用**，其他角色返回 `PERMISSION_DENIED`（不触及存储）。**【已验证】**

| action | params | 成功 data | 主要错误码 |
| --- | --- | --- | --- |
| `create` | `name`, `role` | `account`（含生成的 id/actor_id） | `ACCOUNT_NAME_TAKEN`、`INVALID_ACCOUNT_ROLE`、`INVALID_ACCOUNT_NAME` |
| `disable` / `enable` | `account_id` | `account_id`, `disabled` | `ACCOUNT_NOT_FOUND` |
| `issue` | `account_id`, `ttl_ms` | `token`（明文，仅此一次）, `expires_at_ms` | `ACCOUNT_NOT_FOUND`、`ACCOUNT_DISABLED`、`INVALID_SESSION_TTL` |
| `revoke` | `token` **或** `account_id`（二者恰一） | `revoked`（数量） | `REVOKE_TARGET_REQUIRED`、`ACCOUNT_NOT_FOUND` |
| `list` | （空） | `accounts`, `sessions`（仅哈希） | — |
| `audit` | 可选 `limit`（1–200，默认 50） | `audit`（按插入序倒序） | — |

其他 action 返回 `UNSUPPORTED_ACCOUNT_ACTION`；键不齐或类型错误返回 `INVALID_ACCOUNT_REQUEST`。**【已验证】**

语义要点：

- `disable` 在同一事务内撤销该账户全部存活会话；在线客户端一帧内被断开。**【已验证】**
- `enable` 不复活已撤销会话；需要重新 `issue`。**【已验证】**
- 权威重启后账户与会话完整恢复，已签发令牌继续可用。**【已验证】**
- 管理操作写 `audit_log`；会话校验（含失败）也记录。**【已验证】**

## 4. 明确边界

- 无账户删除、无角色变更接口；owner 不能通过本接口移除最后一个可用 owner 的保护**【不支持】**（当前需直接维护数据库，列为后续项）。
- V4 导出包（region-lab.bundle v1）不含身份表；跨机搬移身份需复制 `worlds.sqlite3`。**【不支持】**
- 角色目前只影响管理接口与既有变更授权（observer 只读）；对象级细粒度权限属 V6-2。**【不支持】**
- 无速率独立的暴力破解防护：令牌为 256 位随机、仅存哈希，认证失败即断开并计入五秒认证超时与每秒消息限额；专项目枚举防护未实现。**【已实现】**
- HTTPS 资产端点仍按配置主体校验 Bearer 令牌，暂未切换到会话表；统一资产授权属 V6-3。**【不支持】**

## 5. 验证基线（2026-09-21，本机）

- `services/Test-Store.py`：87/87（schema 4 初始化、身份操作 34 项、v3→v4 迁移回滚与重试）。
- `services/Test-Identity.cjs`：29/29（owner 引导、建号、签发、连接、撤销踢出、禁用级联、重启持久、审计）。
- `services/Test-Network.cjs`：63/63 回归（含过期令牌拒绝；六米/秒时序用例偶发失败，重跑通过）。
- `services/Test-DesktopStore.ps1`：6/6。
