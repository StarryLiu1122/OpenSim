# 原始 GLB 验证样本

本目录模型、内嵌纹理由 Region Lab contributors 为本项目生成，采用 [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) 贡献至公有领域。生成脚本属于项目代码，沿用仓库代码许可证。无第三方模型、图片或扫描数据。

| 文件 | 内容 | 碰撞 |
| --- | --- | --- |
| pavilion.glb | 10.6×8.6×3.8 米建筑，约 2.4 米宽入口 | 独立地板、墙、门楣、屋顶代理；保留内部空间 |
| bench.glb | 2.4 米长凳，木纹基础色 PNG | 可见几何直接参与静态碰撞 |
| tree.glb | 约 4×3.80×6 米的低面数树 | 仅树干代理，树冠可穿过 |

模型使用 glTF Y 向上坐标、米制单位；实例维度按区域 X 东、Y 北、Z 高排列。原始模型较简化，用于导入、复用、碰撞和存档测试，不代表真实场景精度。

在仓库根目录可选执行：

```powershell
python prototype/tools/Generate-SampleAssets.py
```

该脚本只依赖 Python 3 标准库，生成确定性的 GLB 字节。正常安装、启动和测试直接读取已提交样本，不需要 Python。导入界面填写许可 `CC0-1.0`、作者 `Region Lab contributors`。
