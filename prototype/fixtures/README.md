# 测试样本

| 文件 | 用途 |
| --- | --- |
| [create-and-save.commands.json](create-and-save.commands.json) | 创建固定 ID 方块、保存和查询；重复用于同一世界会触发 ID 冲突 |
| [sculpt-and-save.commands.json](sculpt-and-save.commands.json) | 在 [80,80] 设高，执行撤销、重做、保存及查询 |
| [v1-region.snapshot.json](v1-region.snapshot.json) | V1 实际引擎生成的快照，用于 V2 读取和再次保存验证 |

V1 样本由提交 `89ecdfabbc919fc11ef059bc6dfcbaf8667c1a58` 对应的独立进程测试生成，包含演示地形和测试物体 `44444444-4444-4444-8444-444444444444`。该物体的位置为 `[45.25,72.5,3.75]`，尺寸为 `[2.5,3.5,4.5]`。样本不包含用户数据或凭据。

兼容性测试将样本复制到当次临时目录后操作，不直接改写仓库内的样本。编辑命令样例须指定独立世界路径。
