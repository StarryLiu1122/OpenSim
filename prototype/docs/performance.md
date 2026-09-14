# V3.1 性能基线方法

## 1. 目的与复现

本基线记录固定场景的本机运行特征，用于后续版本比较。测量脚本不会打开、修改或保存默认用户世界。

在 prototype 目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Measure-RegionLab.ps1
```

输出位于 `test-results/benchmark-.../`，包含 benchmark.json、日景/夜景截图及引擎日志。需要原生图形会话，拒绝 headless 模式。使用固定 Godot 标准版直接运行源码，不是导出发行构建。

## 2. 固定工作负载

| 设置 | 值 |
| --- | --- |
| 日景 | DemoRegion，43 对象、1 组、7 盏开启的点光源，15.5 时 |
| 夜景 | 同一场景加 100 个长凳和 100 株网格树，共 243 对象、2 个导入资产，20 时 |
| 窗口 | 1280×720；请求关闭垂直同步，Engine.max_fps=0 |
| 相机 | Godot 坐标 (95,44,-82)，目标 (135,2,-140)，FOV 52，远面 700 米 |
| 预热 | 每个场景至少 2 秒且至少 90 帧 |
| 采样 | 每个场景至少 3 秒且至少 180 帧，记录实际帧数 |
| 内容 | 与主程序共用 DemoRegion、WorldView、MeshView、EnvironmentView；不包含编辑面板和移动角色 |

两个场景在同一进程依次运行；第二个场景可能复用驱动及引擎资源缓存。各场景记录从数据构建开始到首次 frame_post_draw 的时间，不包含操作系统创建进程、引擎启动或首次安装。它不是完全冷启动指标。

## 3. 指标解释

- frame_intervals_ms：相邻渲染帧结束信号之间的单调时钟间隔，包括调度与提交开销；不是 GPU timestamp，也不是实际显示器刷新率。
- P50/P95：对全部采样间隔排序，以 nearest-rank 取分位；平均 FPS 为采样帧数除以累计时间。
- draw_calls_max：采样期间 Godot 绘制调用监测值的最大值。
- rendered_primitive_monitor_max：Godot 渲染 primitive 监测值，包含阴影等额外通道，不能当作资产独立三角形数。
- godot_static_memory_max_bytes：采样期间 Godot 内部静态内存监测最大值，不是进程 RSS、总显存或系统内存占用。
- imported_triangles_including_proxies：导入器统计的三角形数乘实例数，包含代理，不包含内置对象和地形。

监测口径以 [Godot Performance 文档](https://docs.godotengine.org/en/4.5/classes/class_performance.html) 为依据。部分监测项存在更新延迟，部分仅在调试构建有效；因此预热和采样均设置时间下限。

## 4. 已记录结果

本次实测使用 Windows 11 10.0.26200、Intel Core Ultra 7 255HX、RTX 5060 Laptop GPU、NVIDIA 592.01、Godot 4.5.1 Compatibility。具体数值与原始间隔见 [benchmark.json](evidence/benchmark.json)；实际输出记录包含相机、分辨率、采样窗口和硬件信息。

| 工作负载 | 对象数 | 场景构建至首帧 / ms | 帧间隔 P50 / ms | P95 / ms | Godot 静态内存峰值 / MiB | 采样帧数 |
| --- | --- | --- | --- | --- | --- | --- |
| 日间展馆 | 43 | 89.51 | 1.225 | 2.011 | 73.67 | 2,199 |
| 网格实例夜景 | 243 | 173.99 | 2.476 | 2.937 | 89.54 | 1,175 |

两个工作负载的采样时长均约 3 秒；绘制调用监测峰值分别为 652 和 2,043。截图：[日景](images/benchmark-demo-day.png)、[夜景](images/benchmark-mesh-district-night.png)。数值保留到表中精度，原始数据以 JSON 为准。

该结果是同机单次短时基线。驱动设置、后台负载、缓存、窗口状态、笔记本供电与散热均可能影响结果。日夜场景的光照条件不同，两个结果不能直接估计单位对象增长成本。后续优化比较应使用相同工作负载、多次独立运行并记录供电与窗口条件。

## 5. 后续优化入口

当前每个实例分别构造 Mesh、Material 和碰撞。先检查资源复用、绘制调用与阴影灯光开销，再评估实例批处理、LOD 和局部空间更新。尚未证明 500 对象、大型扫描资产、动态物理或多人模式的容量，不能把输入上限作为性能承诺。
