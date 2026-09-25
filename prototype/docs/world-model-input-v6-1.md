# V6.1 世界模型输入映射（首个可验收子集）

`tools/Map-WorldModelObservation.py` 为外部世界模型的水位预测提供离线、只读的校验和坐标映射入口。输入必须写明来源、模型及版本、观测/生成/预测 UTC 时间、`EPSG:3879+5773` 坐标和米制单位。它拒绝未知字段、过期观测、未来生成、超过 72 小时的预测、重复采样点、非有限数值及场景边界之外的坐标。输出记录原始输入和场景清单的 SHA-256，以及来源与 Region Lab 的双坐标，便于后续审查和复现。**它不会回注或修改世界。**

使用仓库中的合成数据进行确定性验收：

```powershell
python prototype/tools/Map-WorldModelObservation.py `
  prototype/fixtures/geodata/helsinki-kamppi-250m/manifest.json `
  prototype/fixtures/world-model/helsinki-synthetic-water.json `
  prototype/runtime/world-model/normalized.json `
  --as-of=2026-09-25T08:10:00Z `
  --model-id=synthetic-water-demo --model-version=0.1.0
```

此样例**不是**真实平台结果。`--as-of` 是审核时间，必须显式传入，使相同输入可复测；`--model-id` 和 `--model-version` 指定本次实验接受的模型版本，不匹配的输入会被拒绝；输出路径必须全新。高度仅减去清单记录的源基线，没有解决赫尔辛基来源文件的 EGM96 标签与市政府 N2000 总体说明之间的差异，不能据此做实际洪水判断。

下一步需要真实平台给出接口和可信数据样本，然后实现 FP-06 的批次回注、幂等处理、采用/拒绝回执以及 FP-08/09 实验记录。当前还没有科学任务闭环、专家标注或状态回放。
