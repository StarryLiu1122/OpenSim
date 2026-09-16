# V4 WebGL2 能力探测

该目录提供可复现的浏览器**能力实验**，尚不是 V5 浏览器编辑器。固定 Godot 4.5.1 标准版，使用生产 WorldService、GLB 读取、WorldView 和角色碰撞代码。根据 [Godot 4.5 官方 Web 导出说明](https://docs.godotengine.org/en/4.5/tutorials/export/exporting_for_web.html)，此版本通过 Compatibility/WebGL2 运行，不提供本项目所需的 Godot WebGPU 后端；C# 仓储进程不会在浏览器中执行。

## 固定输入与复现

1. 按 [web.lock.json](web.lock.json) 下载官方 `Godot_v4.5.1-stable_export_templates.tpz`，1,355,592,535 字节；该模板全集约 1.36 GB，不进入 Git。
2. 准备 Godot 4.5.1 标准 Windows x64 引擎；运行以下命令。目标目录必须不存在。

```powershell
.\integration\web\Install-Templates.ps1 -Archive 'D:\Downloads\Godot_v4.5.1-stable_export_templates.tpz' -Destination 'D:\Tests\Web templates'
.\integration\web\Export-Probe.ps1 -Godot 'D:\Godot\Godot_v4.5.1-stable_win64_console.exe' `
  -Templates 'D:\Tests\Web templates' -Destination 'D:\Tests\Web export'
```

3. 测试机安装 Node.js 与 Playwright 1.62.1，并安装该版本对应 Chromium/Firefox。可在独立工具目录执行 `npm install playwright@1.62.1` 和 `npx playwright install chromium firefox`；这些是测试依赖，桌面程序不依赖 Node/Python。
4. 将该工具目录的 `node_modules` 配到 `NODE_PATH`；若自定义浏览器下载路径，还需设置 `PLAYWRIGHT_BROWSERS_PATH`。

```powershell
node .\integration\web\test-probe.cjs 'D:\Tests\Web export' `
  .\prototype\fixtures\meshes\bench.glb 'D:\Tests\Web results'
```

脚本启动仅绑定 127.0.0.1 的临时 HTTP 服务，不发布到公网，测试完成后关闭浏览器和服务。每组使用独立浏览器上下文；报告和截图保存到新目录。

## 验证矩阵与部署条件

| 配置 | Chromium 151.0.7922.34 | Firefox 153.0 | 已验证结果 |
| --- | --- | --- | --- |
| Jolt，单线程 | 通过 | 通过 | 地形、角色、门、静态 GLB 与 11 项场景检查 |
| Jolt，线程启用 | 通过 | 通过 | 同一场景、文件选择导入、IDBFS 保存/重载与缓存 |
| GodotPhysics3D，单线程 | 通过 | 通过 | 可用替代物理后端；不视为与 Jolt 数值一致 |
| 线程启用，移除隔离头 | 按预期拒绝启动 | 按预期拒绝启动 | 缺 cross-origin isolation / SharedArrayBuffer 的部署反例 |

正例使用 `Cross-Origin-Opener-Policy: same-origin`、`Cross-Origin-Embedder-Policy: require-corp`，WASM MIME 为 `application/wasm`。本机 localhost 属可用安全上下文；公网需 HTTPS，并保证所有子资源满足隔离策略。未验证 Safari、移动端、跨站 iframe 或 CDN 多源配置。

浏览器文件选择通过 JavaScript File API 读取字节，在浏览器虚拟文件系统写入后经过同一生产 GLB 校验器。没有将用户系统路径暴露给服务端。缓存验证记录每次请求与重载网络文件；HTML 保持更新，资源可命中缓存。Godot 的持久化是异步 IDBFS，测试在写入后等待 3 秒并实际重载核对；浏览器清理站点数据会删除本地保存，不能作为服务器备份。

导出器复制项目与引擎到独立目录，使用 `_sc_` 自包含编辑器数据，避免写用户的 Godot 全局编辑器配置。证据见 [V4 验收报告](../../docs/comparisons/v4-completion.md)。后续 V5.1 才将浏览器接入现代权威服务，并重新验证文件、会话、断线和 UI 行为。
