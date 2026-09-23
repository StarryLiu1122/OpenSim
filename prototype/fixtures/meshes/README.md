# 原始 GLB 验证样本

`pavilion.glb`、`bench.glb`、`tree.glb` 及其内嵌纹理由 Region Lab contributors 为本项目生成，采用 [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) 贡献至公有领域。生成脚本属于项目代码，沿用仓库代码许可证。

| 文件 | 内容 | 碰撞 |
| --- | --- | --- |
| pavilion.glb | 10.6×8.6×3.8 米建筑，约 2.4 米宽入口 | 独立地板、墙、门楣、屋顶代理；保留内部空间 |
| bench.glb | 2.4 米长凳，木纹基础色 PNG | 可见几何直接参与静态碰撞 |
| tree.glb | 约 4×3.80×6 米的低面数树 | 仅树干代理，树冠可穿过 |

`polyhaven-marble-bust-01.glb` 是额外的**第三方写实资产导入验收样本**：[Poly Haven 原作](https://polyhaven.com/a/marble_bust_01)，作者 Rico Cilliers，按 [CC0 1.0](https://polyhaven.com/license) 发布；本文件取自 [three.ws 的 1K GLB 转换目录](https://github.com/nirholas/three.ws/blob/main/docs/object-library.md)，SHA-256 为 `241829957a62f742d36772d13e3137a55d5f9e12da9cd4039c9fc35cc59c5742`。它有 JPEG 底色、法线和粗糙度贴图，且网格中含有退化三角形，用于确认下载的写实资产能通过完整导入、渲染和碰撞路径。该作品不是指定真实地点的测绘扫描，也不是项目生成脚本的输出。

模型使用 glTF Y 向上坐标、米制单位；实例维度按区域 X 东、Y 北、Z 高排列。原始模型较简化，用于导入、复用、碰撞和存档测试，不代表真实场景精度。

在仓库根目录可选执行：

```powershell
python prototype/tools/Generate-SampleAssets.py
```

该脚本只依赖 Python 3 标准库，生成确定性的 GLB 字节。正常安装、启动和测试直接读取已提交样本，不需要 Python。导入界面填写许可 `CC0-1.0`、作者 `Region Lab contributors`。
