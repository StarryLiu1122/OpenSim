# ADR-001：单区域原型选择 Godot

日期：2026-09-14。结论：使用 Godot 4.5.1 标准版、Compatibility 渲染器、内置 Jolt、GDScript，先建立本机验证原型。

## 选择依据

本次需要的是一个小规模、可编辑、可保存、可自动测试的区域，不以大型城市画面或现有商业游戏资产为首项验收。引擎承担图形、碰撞、角色运动和界面，项目代码承担世界语义、数据校验、命令与持久化。

| 候选 | 本任务判断 | 决定 |
| --- | --- | --- |
| Godot | 单一标准版发行包即可运行项目；图形、UI、物理和无界面脚本测试可在同一引擎完成；GameFactory 有明确适配参考 | 采用并实测 |
| Unity | 也能承接原型，适合已有 Unity 项目、团队经验或资产依赖时；本次未发现必须依赖的 Unity 能力 | 保留为候选，未安装或做等量性能比较 |
| Unreal Engine | 可作为复杂视觉场景的候选；本次验收不要求其高级画面能力，引入另一套工程不会直接解决世界数据问题 | 暂不采用，未做性能优劣结论 |

这是针对本项目范围和实施成本的选择，不是三个引擎的通用排名。[Godot 功能文档](https://docs.godotengine.org/en/4.5/about/list_of_features.html)、[Unity 安装文档](https://docs.unity3d.com/Manual/GettingStartedInstallingUnity.html)、[Unreal 安装入口](https://dev.epicgames.com/documentation/en-us/unreal-engine/installing-unreal-engine)。

## 版本与语言

固定版本与校验值见 [engine.lock.json](../engine.lock.json)。采用 4.5.1 是为了与 GameFactory 已描述的 Godot 参考组合对齐，不表示它是最新发行版；以后升级需重新运行本项目验证关口。

GDScript 用于引擎侧功能和简单数据服务，使首版只需要一种运行时。C# 源码继续作为语义参考；没有把现有代码机械翻译为 GDScript。Python/FastAPI 和 PostgreSQL 的引入推迟到持久化服务阶段，C++ 待实际热点出现后再评估。

JSON 快照已经满足本次“关闭程序后恢复”的验收。它不替代原计划 M4 的数据库事务、迁移和部署工作，因此 M4 只完成快照部分。

## GameFactory 参考记录

固定参考提交：[378a7a733c0975cdb3b3cd924824652e6bbb66de](https://github.com/OpenDCAI/GameFactory-3A/tree/378a7a733c0975cdb3b3cd924824652e6bbb66de)。参考对象包括 [Godot 适配器](https://github.com/OpenDCAI/GameFactory-3A/tree/378a7a733c0975cdb3b3cd924824652e6bbb66de/engine_adapters/godot)、[工作流程](https://github.com/OpenDCAI/GameFactory-3A/blob/378a7a733c0975cdb3b3cd924824652e6bbb66de/agent_skills/setting_overview.md)和[测试分层](https://github.com/OpenDCAI/GameFactory-3A/blob/378a7a733c0975cdb3b3cd924824652e6bbb66de/agent_skills/develop_harness/README.md)。

| 借鉴的做法 | 当前实现 |
| --- | --- |
| 为智能体提供稳定的引擎入口 | `WorldService` 的版本化命令，加离线 JSON 批处理入口；UI 也走同一路径 |
| 结构化返回结果 | 成功、操作名、请求 ID、修订、结果、警告和错误分开返回 |
| 数据与具体引擎操作分层 | Schema / Model / Service 与 WorldView、Repository 分开 |
| 不以“代码生成完成”作为验收 | 跑原生物理、实际控件事件、两个独立进程恢复、真实渲染截图 |
| 先验证低成本契约，再做实际引擎集成 | 数据校验先测；最终仍要求 Jolt、界面及文件系统参与的集成结果 |

本次借鉴工作方法和接口组织，没有将 GameFactory 整仓库、模型权重、生成资产或其代码作为运行依赖，也没有运行它的完整游戏生成链。原型不具备大模型推理能力；自动化入口先由确定性 JSON 命令验证。

## 实施中验证出的具体问题

1. 对浮点数重新序列化再计算摘要，可能与第一次写入的文本不一致。改为对存储封装中的原始 `world_json` 字符串计算 SHA256，再校验并解析数据。
2. 属性框显示精度低于实际存储精度。现在未修改的数值保留原始值，仅改名称不会顺带改变位置。
3. 将数据北向映射到 Godot 的负 Z，需要反转高度场碰撞数据行序。用实际射线和角色落地测试验证。
4. Windows PowerShell 5.1 的进程退出码获取及默认文本编码不同于开发终端；脚本固定句柄与 UTF-8 读取，并以该版本进行复验。
5. 从 PowerShell 7 经 CMD 调用 Windows PowerShell 5.1 时，继承的模块搜索路径会使部分系统命令无法加载。CMD 入口在局部环境中重建系统 PowerShell 模块路径，并保留失败退出码；不修改系统配置。

后续更换数据库或增加网络时，保留这些功能验收，不以更换框架代替行为验证。
