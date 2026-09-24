# 3DBAG 真实建筑验收数据

`delft-julianalaan-source.json` 是从 [3DBAG 3D API](https://api.3dbag.nl/collections/pand/items?bbox=85000,446700,85070,446770&limit=50) 下载的 CityJSONFeature 响应，SHA-256：`6107c936742816af99efa769b6dca60ba17b692f40bb2bf70e4c5752db4f53a7`。目录 `delft-julianalaan/` 内的 GLB 是此响应的 LoD2.2 几何派生文件，详见 [转换说明](../../docs/delft-real-city-pilot.md)。

数据许可：[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。指定署名：**© 3DBAG by tudelft3d and 3DGI**；[3DBAG 版权与使用要求](https://docs.3dbag.nl/en/copyright/)。转换进行了三角化、局部平移、高程基准平移和演示着色；未添加实拍立面纹理。

## 赫尔辛基实景街区

`helsinki-kamppi-textured/` 保存赫尔辛基市 2017 年航拍三维网格的 16 个连续 LoD 19 样块。每个 GLB 内嵌来源 JPEG 纹理；范围、来源 ZIP、原始文件校验值和转换说明见 [`manifest.json`](helsinki-kamppi-textured/manifest.json)与[实景街区说明](../../docs/helsinki-textured-city-pilot.md)。许可为 CC BY 4.0，署名 **© City of Helsinki, Helsinki 3D Mesh 2017**。
