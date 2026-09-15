# 项目文档库

本目录集中管理项目目标来源、技术决策、版本规划及历史材料。当前实现版本为 Region Lab V3.1 / 0.3.1；规划中的功能只有在代码、测试和验证记录齐备后才标记为交付。

## 项目目标与规划

| 文档 | 用途 |
| --- | --- |
| [老师提供的原始材料](references/teacher/2026-09-15/README.md) | 2026-09-15 两份 Word 原件、版本与摘要校验 |
| [目标与技术路线对齐](plans/platform-integration-alignment.md) | 逐项对应原文目标、当前能力、FP 接口、工程调整及待确认输入 |
| [总体版本路线](plans/stage-one-rebuild-plan.md) | 个人推进顺序、各子版本范围、依赖与验收 |
| [V4 实施计划](plans/v4-implementation-plan.md) | 原版对照、Web 预验证、融合网关和数据库的详细任务 |

## 当前原型

| 文档 | 用途 |
| --- | --- |
| [使用说明](../prototype/README.md) | 环境、安装、操作、保存、测试与故障处理 |
| [架构与接口](../prototype/docs/architecture-and-api.md) | 世界格式 3、命令封装 1、模块职责与存储语义 |
| [组合与资产规范](../prototype/docs/groups-and-assets.md) | 组关系、变换、GLB 支持范围与限制 |
| [OpenSim 数据对应](../prototype/docs/opensim-data-mapping.md) | 固定源码对应及尚未验证的语义 |
| [技术选型](../prototype/docs/engine-decision.md) | 已实施的引擎、语言、地形及资产决策 |
| [验证记录](../prototype/docs/verification.md) | 数据、物理、界面、恢复与独立目录证据 |
| [性能基线](../prototype/docs/performance.md) | 同机固定场景的测量口径及限制 |

## 历史与上游

- [V3.1 实施记录](plans/v3.1-implementation-plan.md) 与 [版本说明](../prototype/docs/releases/v3.1.md)。
- [V3 版本说明](../prototype/docs/releases/v3.md) 与 [V2 版本说明](../prototype/docs/releases/v2.md)。
- [源码来源](UPSTREAM.md)、[上游文档](upstream/README.md) 与 [原版构建说明](../BUILDING.md)。
- [早期 C#/.NET 重构指南](opensimulator-stage-one-refactoring-guide.docx)，保留为历史参考。

## 文档维护规则

原始材料保持字节不变，修订另存新版本并登记 SHA256。目标解读和技术核实写入对齐说明，当前 API 写入原型接口文档，未来任务写入版本计划。文档中的建议、示例和指标必须经过技术验证或明确标记为目标，不能直接作为已实现能力。

原始材料于 2026-09-15 归档，规划于 2026-09-16 更新。原文中的 18 个月总体路线与 4 个月客户端计划是项目层参考；个人任务顺序和完成条件以现行版本路线为准。
