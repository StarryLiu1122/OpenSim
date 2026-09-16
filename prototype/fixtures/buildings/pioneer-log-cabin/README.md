# Pioneer Log Cabin：真实历史建筑的简化衍生模型

对象为美国 Wisconsin 州 Milton 的 Pioneer Log Cabin。原始依据是美国国会图书馆保存的 HABS WIS-18（WIS,53-MILT,1-）实测图，1 张，制图者 Herbert W. Bradley。它与用于功能演示的 pavilion/bench/tree 原创样本具有不同来源。

- [原图目录](https://www.loc.gov/pictures/resource/hhh.wi0107.sheet.00001a/)；本目录 `source-habs-wis-18.tif` 保留下载字节。
- [HABS 使用权说明](https://www.loc.gov/rr/print/res/114_habs.html)：本次采用美国政府制作的原始测绘图，属于公有领域。来源署名：Historic American Buildings Survey, Library of Congress, Prints and Photographs Division。
- 本项目制作的 GLB 和转换程序采用 [CC0-1.0](https://creativecommons.org/publicdomain/zero/1.0/)。原图来源权利与衍生成果许可分别登记于 [provenance.json](provenance.json)。

## 尺寸与制作

按图中标注换算，1 英尺 = 0.3048 米：主体宽 15′1.5″（4.6101 m），深 18′4″（5.588 m），前廊深 6′5″（1.9558 m）；屋檐及屋脊高由立面分段尺寸计算为 2.9464 m、4.2418 m。坐标、边界、摘要和简化项均在 provenance 中。

门洞宽 0.84 m、高 1.90 m 来自图上比例估计，估计不确定度 ±0.08 m；墙厚、地板厚和窗宽也是估计值，不能当成现场实测。模型省略隧道、活板门、可进入阁楼及独立圆木。它不是扫描资产、BIM 或经认证的建筑模型。

可见网格 234 三角形，64,384 字节，无纹理。独立 `COL_` 网格提供墙、地板和门洞碰撞，导入后不会以整栋包围盒封闭入口。GLB 为 Y 向上，+Z 指向历史东向入口，+X 指向历史北；不含地理配准。

## 验证与再生成

```powershell
python .\prototype\tools\Generate-DocumentedBuilding.py
.\prototype\tools\Test-DocumentedBuilding.ps1 -Godot 'C:\path\to\Godot_v4.5.1-stable_win64_console.exe' -OutputDirectory 'D:\Tests\new cabin'
```

测试使用 1.8 m 高、0.7 m 直径的原型角色，验证进入、地板着地、墙体和门楣碰撞，删除导入临时源、搬移快照后在另一个引擎进程恢复。几何余量约为宽 0.14 m、高 0.10 m；它仅说明此简化模型与该角色碰撞体能够通行，不是建筑安全净空或无障碍结论。验证结果见 [V4 报告](../../../../docs/comparisons/v4-completion.md)。
