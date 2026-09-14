# OpenSim

基于 **OpenSimulator 0.9.3.0** 的平台现代化项目。当前先理解原版数据模型，再以现代引擎验证单区域功能复现，最后通过明确的世界操作接口接入大模型与智能体。

**本分支 `codex/single-region-prototype` 已实现首个可运行的单区域验证原型。** 使用 **Godot 4.5.1 标准版 + 内置 Jolt 物理 + GDScript**，支持进入行走、方块创建/编辑/删除、撤销、保存及重启恢复。

![Region Lab 实际运行画面](prototype/docs/images/overview.png)

## 先运行原型

Windows PowerShell：

```powershell
git clone --branch codex/single-region-prototype https://github.com/StarryLiu1122/OpenSim.git
cd OpenSim\prototype
.\Install.cmd
.\Start.cmd
```

首次安装下载约 77 MB 的官方引擎包并校验 SHA512；需要 Windows x64、PowerShell 5.1 和支持 OpenGL 3.3 的显卡。无需先安装 .NET、Python、数据库或模型服务。已在 Windows 11 上运行真实引擎验证。

**完整依赖、离线安装、按键、存档位置、测试命令和排错见 [原型 README](prototype/README.md)。**

## 当前范围与进度（2026-09-14）

当前交付是 **本机、单用户、256×256 米区域**。地形和方块由引擎渲染，角色碰撞由 Jolt 求解，版本化 JSON 保存世界数据。UI 和离线自动化共用带校验的命令入口；已经验证 46 项数据/存储/物理检查、18 项实际界面/渲染检查、两个独立进程恢复和离线命令样例，见 [验证记录](prototype/docs/verification.md)。

| 工作 | 当前状态 |
| --- | --- |
| 单区域进入、编辑、保存恢复 | 已实现并验证 |
| OpenSim 数据对应、坐标与生命周期 | 已整理首版对应表，明确尚缺语义 |
| 引擎选型与版本锁定 | 已验证 Godot 4.5.1 / Jolt；未做三个引擎等量性能比较 |
| GameFactory 参考 | 借鉴接口组织和实际引擎验收；未运行其完整生成链 |
| 原 OpenSim 运行基线 | 原代码保留，首次编译和运行对照仍待完成 |
| 数据库、多人同步和身份认证 | 尚未实现；JSON 快照只完成原计划 M4 的一部分 |
| 库存、世界脚本、Firestorm、外部模型和真实 LLM | 后续专题；当前无兼容承诺 |

完整 M0—M7 路线见 [第一阶段实施计划](docs/plans/stage-one-rebuild-plan.md)。当前结果不等于完整替代 OpenSim，也不表示整阶段已完成。下一步先补原版行为对照与地形编辑，再扩展数据库持久化、服务端状态与多人同步。

以下保留早期 C#/.NET 升级路线和原版源码说明，作为维护与兼容性参考。运行此次交付请使用 `prototype/` 中的 Godot 项目。

## 项目文档

- [可运行原型与安装说明](prototype/README.md)：环境、启动、操作和存档。
- [引擎选择与 GameFactory 借鉴](prototype/docs/engine-decision.md)：选择理由、固定参考版本与实际借鉴范围。
- [OpenSim 数据结构对应](prototype/docs/opensim-data-mapping.md)：字段、坐标、资产、库存和存储语义。
- [架构与命令契约](prototype/docs/architecture-and-api.md)：统一入口、自动化调用和后续 AI 辅助开发方法。
- [验证记录](prototype/docs/verification.md)：实际检查、截图和未验证范围。
- [当前第一阶段实施计划（Markdown）](docs/plans/stage-one-rebuild-plan.md)：单区域功能复现、软件栈验证、任务顺序和验收条件。
- [早期 C#/.NET 重构实施指南（Word，15 页）](docs/opensimulator-stage-one-refactoring-guide.docx)：保留为源码构建、依赖迁移与兼容性研究参考。
- [源码来源与导入说明](docs/UPSTREAM.md)：固定上游提交、完整性校验和当前验证范围。
- [上游构建说明](BUILDING.md)与[上游 README 原文](docs/upstream/README.md)。

实施指南编写时使用的是稀疏源码审阅副本。本仓库已经补齐同一提交的全部受版本控制文件，包含 `bin/`、`Prebuild/`、`ThirdParty/` 等构建输入；首次编译和运行验证仍需执行。

## 早期 C#/.NET 升级路线（历史参考）

### 第一阶段 代码与依赖现代化

1. 固定源码与工具链，在独立环境中构建并启动测试世界，保存可以恢复的数据基线。
2. 盘点托管与原生依赖，记录来源、版本、补丁、使用位置及兼容要求。
3. 整理项目文件、项目引用、包管理和发布目录，建立可重复构建流程。
4. 在独立分支验证 .NET 10，专项处理旧脚本状态、插件、图像与物理原生库。
5. 从 NPC 和聊天观察等具体用例入手，拆分业务规则、引擎适配与外部访问。
6. 用确定性的模拟调用端验证世界查询与动作接口，完成回归、异常、性能和回退测试。

全库先盘点，再按约定的模块清单逐批迁移。每批有明确验收，首个用例完成不代表全平台已经完成现代化。

### 第二阶段 大模型与智能体接入

通过独立的模型服务理解用户请求、读取世界观察并选择动作工具。OpenSim 继续维护世界状态、检查权限和执行动作。首个演示目标是单区域中的一个 NPC 能观察环境、回复并移动到已知目标。

模型调用需要与区域事件和模拟循环分离，并处理超时、取消、队列容量、重复命令及区域卸载。这部分目前是规划，尚未实现。

## 早期语言与技术方向（历史参考）

| 部分 | 推荐方向 | 采用条件 |
| --- | --- | --- |
| 世界与业务核心 | 保留 C#，逐步完成现代 .NET 工程与库迁移 | 早期方案，用于保留既有协议、插件和业务基础 |
| 模型服务 | 可以继续使用 C# | 以模型 API、工具调用和会话管理为主时 |
| Python 服务 | 作为独立进程，通过版本化接口连接世界 | 需要复用特定 AI 库、训练推理组件或研究代码时 |
| C++ 或其他原生模块 | 保留现有互操作，按需增加局部计算实现 | 性能测量确认热点，且收益足以抵消跨语言维护成本时 |

早期方案不安排整体语言重写。LSL/OSSL 是世界内脚本接口，与宿主语言选择属于不同层次；若沿用此路线，应保持已有脚本和权限语义。新原型的脚本范围见当前实施计划。

## 代码结构

```text
OpenSim/
  Framework/                  公共类型、工具、服务器基础设施
  Region/
    Application/              区域启动与装配
    ClientStack/              Viewer 通信与能力接口
    Framework/                Scene、角色、物体、事件与模块接口
    CoreModules/              核心区域功能
    OptionalModules/          可选功能及 NPC 模块
    ScriptEngine/             YEngine 与 LSL/OSSL 实现
    PhysicsModules/           物理引擎适配及原生互操作
  Services/                   账户、资产、库存等服务与接口
  Server/                     后端服务入口和请求处理
  Data/                       数据库访问与插件
Prebuild/                     工程生成器源码
ThirdParty/                   随上游维护的第三方源码
ThirdPartyLicenses/           第三方许可证
bin/                          上游构建依赖、原生组件和配置模板
doc/                          上游文档
docs/                         本项目的重构指南与来源说明
prototype/                    Godot 单区域原型、安装脚本、原生测试及说明
prebuild.xml                  原构建的项目与依赖描述
runprebuild.bat / .sh         原工程生成入口
```

`bin/` 中有上游受版本控制的构建输入，不应把整个目录当作可删除的编译缓存。实际运行产生的配置、数据库、日志和世界内容应放在独立实例中管理。

## 原版 C# 源码的构建起点（不用于运行当前原型）

当前源码仍以 **.NET 8** 为目标；**.NET 10 LTS 是待验证的升级目标**。以下步骤沿用固定上游版本的构建方式，不代表已在本仓库验证成功。

Windows 开发环境需要 Git 和 .NET 8 SDK。可选用兼容的 Visual Studio 2022 或更新版本。

```powershell
git clone https://github.com/StarryLiu1122/OpenSim.git
cd OpenSim
dotnet --info
.\runprebuild.bat
dotnet build OpenSim.sln --configuration Release
```

`OpenSim.sln` 和项目文件由原生成流程产生，不要求克隆后立即存在。生成脚本会复制系统相关依赖并处理本地插件缓存，应在独立开发目录中运行。

编译成功后，按 [BUILDING.md](BUILDING.md) 配置独立的 Standalone 测试实例，使用单独的端口、区域和数据库。初始环境可采用 SQLite 与 YEngine，先验证登录、移动、聊天、物体保存及脚本恢复。

Linux 的原构建步骤和依赖也见 `BUILDING.md`；图像与原生库需要在实际目标系统中单独验证，不能用 Windows 结果代替。

.NET 8 的支持于 2026 年 11 月 10 日结束；计划上线前需要完成受支持运行时的迁移与兼容验收。参见 [微软 .NET 支持周期](https://dotnet.microsoft.com/en-us/platform/support/policy)。

## 当前已识别的迁移重点

| 位置或依赖 | 实施重点 |
| --- | --- |
| `prebuild.xml` 与 `bin/` 引用 | 区分仓库内项目、官方包、自维护 DLL 和原生库，逐项固定来源 |
| YEngine 的 `XMRInstAbstract.cs` | 迁移部分状态编码中的 BinaryFormatter，验证旧状态恢复与继续执行 |
| 系统相关的 `System.Drawing.Common` | 核实不同 DLL 的来源，验证图像功能及跨平台行为 |
| OpenMetaverse、Mono.Addins | 保留所需补丁、协议语义和插件生命周期，避免按同名包直接替换 |
| 日志、配置、HTTP 与任务队列 | 用适配层逐步引入现代接口，明确取消、顺序和资源释放 |
| 区域事件与 NPC 操作 | 隔离外部等待，补齐身份、归属、截止时间和重复命令处理 |

不要仅修改目标框架或批量更新全部库版本。一次迁移应包含明确的调用路径、验证用例、产物清单和回退方式。

## 原版升级路线的进度与验证范围（历史参考）

- [x] 导入固定上游提交的全部 2,399 个文件。
- [x] 校验导入快照的文件内容、可执行标记和 Git 树与上游一致。
- [x] 整理第一阶段实施指南、中文项目 README 和来源说明。
- [ ] 完成首次编译与独立测试实例启动。
- [ ] 恢复关键测试并建立当前仓库的持续集成。
- [ ] 完成依赖清单、运行时和旧状态迁移验证。
- [ ] 实现用例服务、世界契约与引擎适配模块。
- [ ] 接入真实模型并完成智能 NPC 验收。

上游 `TESTING.txt` 包含历史工具说明，不能据此判断测试已经可运行。保留的上游 GitHub Actions 工作流也尚未改造为本仓库的验证流程。

## 上游与许可证

本项目基于 [OpenSimulator](https://github.com/opensim/opensim)，当前初始代码来自 `0.9.3.0` 分支提交 [`1f4a6dd1d3ff653ecc2748a7764106c30ac4ef9d`](https://github.com/opensim/opensim/tree/1f4a6dd1d3ff653ecc2748a7764106c30ac4ef9d)。它作为源码快照导入，未复制完整上游提交历史。

保留上游版权声明、[LICENSE.txt](LICENSE.txt)、[CONTRIBUTORS.txt](CONTRIBUTORS.txt) 和 [ThirdPartyLicenses](ThirdPartyLicenses/)。第三方组件分别遵循其许可证。本仓库的重构规划不表示 OpenSimulator 官方已采纳或完成这些改动。
