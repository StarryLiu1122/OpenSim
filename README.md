# OpenSim

基于 **OpenSimulator 0.9.3.0** 的平台现代化项目，目标是逐步改善代码结构、构建和依赖管理，并通过清晰的世界操作接口接入大模型与智能体。

当前仓库提供完整的上游源码快照、构建输入和第一阶段实施指南。**目前处于重构起始阶段：业务代码尚未改造，尚未完成本仓库的编译、运行与兼容性验证。**

## 项目文档

- [第一阶段重构实施指南（Word，15 页）](docs/opensimulator-stage-one-refactoring-guide.docx)：语言选型、源码构建、工程与依赖迁移、运行时升级、模块拆分、测试和回退。
- [源码来源与导入说明](docs/UPSTREAM.md)：固定上游提交、完整性校验和当前验证范围。
- [上游构建说明](BUILDING.md)与[上游 README 原文](docs/upstream/README.md)。

实施指南编写时使用的是稀疏源码审阅副本。本仓库已经补齐同一提交的全部受版本控制文件，包含 `bin/`、`Prebuild/`、`ThirdParty/` 等构建输入；首次编译和运行验证仍需执行。

## 重构路线

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

## 语言与技术方向

| 部分 | 推荐方向 | 采用条件 |
| --- | --- | --- |
| 世界与业务核心 | 保留 C#，逐步完成现代 .NET 工程与库迁移 | 当前主路线，保留既有协议、插件和业务基础 |
| 模型服务 | 可以继续使用 C# | 以模型 API、工具调用和会话管理为主时 |
| Python 服务 | 作为独立进程，通过版本化接口连接世界 | 需要复用特定 AI 库、训练推理组件或研究代码时 |
| C++ 或其他原生模块 | 保留现有互操作，按需增加局部计算实现 | 性能测量确认热点，且收益足以抵消跨语言维护成本时 |

第一阶段不安排整体语言重写。LSL/OSSL 是世界内脚本接口，与宿主语言选择属于不同层次；迁移时需要保持已有脚本和权限语义。

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
prebuild.xml                  原构建的项目与依赖描述
runprebuild.bat / .sh         原工程生成入口
```

`bin/` 中有上游受版本控制的构建输入，不应把整个目录当作可删除的编译缓存。实际运行产生的配置、数据库、日志和世界内容应放在独立实例中管理。

## 构建起点

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

## 当前进度与验证范围

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
