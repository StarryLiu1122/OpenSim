# OpenSim 平台重建

本项目以 OpenSimulator 0.9.3.0 的区域、地形、物体和持久化模型为参考，采用现代游戏引擎实现可逐步扩展的三维区域系统。仓库保留原版 C# 源码，并在 `prototype/` 中独立开发 Region Lab。

当前版本：**Region Lab V2（0.2.0）**。运行环境为 **Godot 4.5.1 标准版、Jolt 物理、GDScript**；交付范围为本机单用户、256×256 米区域。

![Region Lab V2 地形编辑](prototype/docs/images/terrain.png)

## 功能范围

| 模块 | V2 功能 |
| --- | --- |
| 区域与角色 | 高度场地形、区域边界、行走、跳跃、角色碰撞 |
| 物体编辑 | 创建、选择、复制、删除；名称、位置、尺寸、旋转和颜色编辑 |
| 地形编辑 | 抬升、降低、设高、平滑；地表拾取、坐标定位和笔刷范围预览 |
| 编辑历史 | 物体与地形统一撤销、重做，最多保留 30 次编辑 |
| 持久化 | 物体与地形整体保存、重启恢复、校验和与有效备份；兼容 V1 存档 |
| 自动化 | 版本化命令入口、离线 JSON 批处理、原生引擎与界面测试 |

多人同步、数据库服务、完整身份权限、库存、LSL/OSSL、Firestorm 协议及外部模型导入列入后续版本。当前未集成在线大模型服务。

## 安装与启动

Windows x64 环境需要 PowerShell 5.1、支持 OpenGL 3.3 的显卡及正常驱动。

```powershell
git clone --branch codex/region-lab-v2 https://github.com/StarryLiu1122/OpenSim.git
cd OpenSim\prototype
.\Install.cmd
.\Start.cmd
```

安装脚本下载并校验官方 Godot 发行包，约 77 MB。原型运行不依赖 .NET SDK、Python、数据库或 API Key。离线安装、指定存档、操作说明和故障处理见 [使用说明](prototype/README.md)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [使用说明](prototype/README.md) | 依赖、安装、启动、编辑、保存恢复和测试命令 |
| [架构与接口](prototype/docs/architecture-and-api.md) | 模块职责、世界格式、命令契约和存储规则 |
| [OpenSim 数据对应](prototype/docs/opensim-data-mapping.md) | 源码入口、字段映射、坐标、地形与存储语义 |
| [技术选型](prototype/docs/engine-decision.md) | 引擎选择、语言分工及 GameFactory 参考范围 |
| [验证记录](prototype/docs/verification.md) | 测试环境、结果、兼容性和验证边界 |
| [V2 版本说明](prototype/docs/releases/v2.md) | 版本范围、接口变化、兼容性和已知限制 |
| [后续开发计划](docs/plans/stage-one-rebuild-plan.md) | 按交付条件组织的版本路线与任务清单 |
| [源码来源](docs/UPSTREAM.md) | 固定上游提交及源码导入记录 |

早期 [C#/.NET 重构指南](docs/opensimulator-stage-one-refactoring-guide.docx) 保留为原版维护参考；当前实施范围以版本说明和开发计划为准。

## 仓库结构

```text
prototype/
  godot/domain/       世界数据、命令服务、地形算法
  godot/adapters/     引擎场景、碰撞、快照存储
  godot/client/       角色、物体编辑与地形界面
  godot/tests/        数据、物理、界面与跨进程测试
  godot/tools/        离线命令执行入口
  tools/             Windows 安装、启动和测试脚本
  fixtures/          自动化样例与 V1 存档样本
  docs/              设计、使用、版本和验证文档
OpenSim/             原版区域、服务、脚本、物理和数据访问源码
Prebuild/            原版工程生成工具
ThirdParty/          原版第三方源码
bin/                 上游受版本控制的依赖与配置模板
docs/                项目计划、历史指南与来源说明
```

## 开发与测试

在 `prototype` 目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-RegionLab.ps1 -Visual
```

测试使用独立目录，输出 JSON 报告、引擎日志及界面截图。新增世界操作须经过命令服务，包含相应数据校验及行为测试；开发约定见 [AGENTS.md](prototype/AGENTS.md)。

原版 C# 工程的生成与构建方法见 [BUILDING.md](BUILDING.md)。当前尚未完成固定源码版本的运行对照，该项在后续计划中单独验收。

## 上游与许可证

原版源码来自 [OpenSimulator 0.9.3.0](https://github.com/opensim/opensim/tree/1f4a6dd1d3ff653ecc2748a7764106c30ac4ef9d)，固定提交为 `1f4a6dd1d3ff653ecc2748a7764106c30ac4ef9d`。仓库保留 [LICENSE.txt](LICENSE.txt)、[CONTRIBUTORS.txt](CONTRIBUTORS.txt) 和 [ThirdPartyLicenses](ThirdPartyLicenses/)。第三方组件适用各自许可证。
