# 资产库存合同：V6-3（FP 0.3 能力扩展）

适用：Region Lab 0.6.0（V6-3）。扩展 [身份合同](identity-v6.md)、[权限合同](permits-v6.md)；`fp_version` 保持 `"0.3"`。数据库 schema 6，导出包版本 2。

状态标注：**【已验证】** / **【已实现】** / **【不支持】**，同前。

## 1. 三层分离模型

| 层 | 载体 | 说明 |
| --- | --- | --- |
| 内容 | `contents` 表 + `objects/<sha256>.glb` | 哈希寻址，全库唯一一份 |
| 世界资产 | `assets` 表 | 场景注册；多个可指向同一内容 |
| 库存条目 | `inventory_items` 表 | 按 `asset_sha256` 引用内容，只存元数据 |

- 同一内容服务多个世界资产、多个场景实例、多个库存条目。**【已验证】**（两次放置→一条世界资产记录、两个实例、一个内容文件）
- 删除场景实例不影响库存条目；删除库存条目不影响场景。**【已验证】**
- GC 把库存引用计入存活集：仅库存引用的内容不会被回收；引用移除后才回收。**【已验证】**
- `inventory_folders` 为账户内树；条目可位于根或文件夹。**【已验证】**

## 2. 管理接口（`type:"inventory"`，仅本人库存）

请求键恰好为 `{ fp_version, type, request_id, action, params }`；回复 `inventory_result: { request_id, ok, code, data }`。所有角色可管理本人库存；看不到也探不到他人条目。**【已验证】**

| action | params | 成功 data | 主要错误码 |
| --- | --- | --- | --- |
| `list` | （空） | `folders[]`, `items[]` | — |
| `folder_create` | `name`，可选 `parent_id` | `folder` | `FOLDER_NOT_FOUND`、`INVALID_FOLDER_NAME` |
| `add` | `asset_id`（世界网格资产），可选 `name`、`folder_id` | `item` | `ASSET_UNKNOWN`、`FOLDER_NOT_FOUND`、`CONTENT_UNKNOWN` |
| `move` | `item_id`，可选 `folder_id`（缺省回根） | `item_id`, `folder_id` | `ITEM_NOT_FOUND`、`FOLDER_NOT_FOUND` |
| `give` | `item_id`, `to_account_id` | `item_id`, `to_account_id` | `ITEM_NOT_FOUND`、`ACCOUNT_NOT_FOUND`、`ACCOUNT_DISABLED` |
| `remove` | `item_id` | `removed` | `ITEM_NOT_FOUND` |

其他 action 返回 `UNSUPPORTED_INVENTORY_ACTION`；键不齐或类型错误返回 `INVALID_INVENTORY_REQUEST`。**【已验证】**

## 3. 放置命令（`PlaceInventoryItem`）

- 已加入操作白名单，走标准命令队列（pending→result，CAS 提交，持久回执）。**【已验证】**
- 载荷：`{ item_id, position:[x,y,z]，可选 name }`。服务器复用同哈希世界资产，缺失时先从库存内容 `ImportGlb` 再 `CreateObject`，同一候选世界内完成。**【已验证】**
- observer 在命令入口被拒（`PERMISSION_DENIED`）；条目不存在返回 `ITEM_NOT_FOUND`；载荷非法返回 `INVALID_PLACEMENT`。**【已验证】**
- 放置不消耗库存条目（引用语义，非一次性消耗品）。**【已验证】**

## 4. 导出包 v2

- 新增 `service.json`：账户、受限、授权、库存文件夹与条目；**不含会话与审计**（会话属运行期，由配置主体引导重新签发）。**【已实现】**
- 纯库存引用的内容文件随包携带；恢复时与世界同事务落库，冲突整体回滚。**【已验证】**
- v1 包继续可导入（仅世界）。**【已验证】**
- 恢复目标应为空根；服务表冲突（如重名账户）使整个导入失败，不留部分提交。**【已实现】**

## 5. 明确边界

- 授予=转移，无副本语义；copy/no-copy 权限位**【不支持】**。
- 文件夹删除**【不支持】**（级联策略未定）。
- 条目级共享可见性**【不支持】**：条目仅持有者可见可用。
- 库存容量配额**【不支持】**。

## 6. 验证基线（2026-09-21，本机）

- `services/Test-Store.py`：130/130（库存操作、GC 存活、v2 包往返含账户/权限/库存、v1 包兼容、v5→v6 迁移回滚）。
- `services/Test-Inventory.cjs`：31/31（上传→入库存→两次放置共享内容→删实例→授予→移除→重启持久）。
- `services/Test-Identity.cjs` 29/29、`services/Test-Permit.cjs` 37/37 回归。
- `services/Test-Network.cjs`：同 V6-2 记录的环境性时序抖动（对照组同现），开放项待空闲窗口补测。
