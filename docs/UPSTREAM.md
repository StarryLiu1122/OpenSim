# 源码来源与导入说明

## 固定基线

| 项目 | 值 |
| --- | --- |
| 上游仓库 | https://github.com/opensim/opensim |
| 参考分支 | `0.9.3.0` |
| 固定提交 | `1f4a6dd1d3ff653ecc2748a7764106c30ac4ef9d` |
| 上游 Git 树 | `fbf3a3c632b08e6d90a3afd519e9577fa20eb695` |
| 本仓库初始导入提交 | `d9f40880cf5ee8cfc8638bc3566c9e56b71221a5` |
| 上游受版本控制文件 | 2,399 个 |
| 文件总字节数 | 97,314,443 |
| 导入方式 | 固定提交的完整源码快照，不包含更早的上游提交历史 |

初始导入提交保留了上游全部文件内容和 Git 可执行标记，其 Git 树与固定上游提交完全一致。后续文档提交替换仓库根 README，并新增本项目文档，业务源码和上游构建文件保持初始导入内容。

## 完整性校验

下载地址：

```text
https://codeload.github.com/opensim/opensim/zip/1f4a6dd1d3ff653ecc2748a7764106c30ac4ef9d
```

本次下载的 ZIP SHA256：

```text
abb006e674976cb21adc6e75578cdad3b86b3ac91c0d82e3ab060c8e5771e0f2
```

逐文件按 Git blob 算法校验内容，再比较文件列表、文件模式与最终 Git 树。ZIP 校验值用于记录本次下载，固定提交和 Git 对象校验是源码一致性的依据。

## 构建输入与验证状态

仓库包含固定提交中的 `bin/`、`Prebuild/`、`ThirdParty/`、`ThirdPartyLicenses/`、资源与配置模板。`bin/` 下受版本控制的预编译组件和原生库属于上游构建输入，随快照保留；它们不是本项目已经编译验证的产物。

当前仅完成源码完整性与文档入库检查，尚未完成首次编译、测试运行、.NET 10 兼容或依赖安全审计。后续逐项盘点这些组件的版本、来源、许可与目标平台。

早先用于静态审阅的桌面副本为稀疏检出；本次导入已补齐同一提交的全部受版本控制文件。实施指南中有关稀疏副本的描述反映编写时的审阅环境。

此前安装包的版本号为 OpenSim 0.9.3.0 Nessie Dev，尚不能据此证明它与本固定提交完全对应。首次运行验证应使用独立测试世界，保存实际行为基线。

## 上游文档与版权

原始根 README 保存在 [upstream/README.md](upstream/README.md)，原文中的相对路径按源码根目录理解。

上游 [LICENSE.txt](../LICENSE.txt)、[CONTRIBUTORS.txt](../CONTRIBUTORS.txt)、各文件版权头及 [ThirdPartyLicenses](../ThirdPartyLicenses/) 保持原样。未来引入上游更新时，应记录新的固定提交、选择性补丁及对应验证结果。
