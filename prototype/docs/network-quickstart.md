# V5 网络区域运行指南

适用版本：0.5.1，Windows x64。已有 V3.1/V4 的 Godot 4.5.1 标准版可以继续使用。`prototype/Start.cmd` 打开原有离线编辑器；V5 共享区域使用下列独立入口。测试主体不是正式用户账户系统。

## 1. 一次性准备

需要 PowerShell 7、.NET SDK **8.0.424**（构建），以及 **ASP.NET Core 8 Runtime**（运行，包含 .NET Runtime）。安装 SDK 的开发电脑已具备这些运行时。Python 和 Node.js 仅用于开发测试；正常运行不需要模型服务或 API Key。

在 PowerShell 7 中进入仓库根目录，更新 main 分支：

```powershell
git fetch origin
git switch main
git pull --ff-only origin main
$godot = 'C:\path\to\Godot_v4.5.1-stable_win64_console.exe'
$storeBuild = Join-Path $PWD 'services\runtime\v5-store'
$hostBuild = Join-Path $PWD 'services\runtime\v5-host'
.\services\Build-Store.ps1 -OutputDirectory $storeBuild
.\services\Build-Host.ps1 -OutputDirectory $hostBuild
$store = Join-Path $storeBuild 'runtime\RegionStore.exe'
$gateway = Join-Path $hostBuild 'runtime\RegionHost.exe'
```

构建脚本要求使用新输出目录；再次构建可改变目录后缀。运行时与引擎版本、离线安装方法分别见 [仓储工具](../../services/README.md) 和 [原型说明](../README.md)。

## 2. 创建共享区域并打开两个桌面客户端

```powershell
$instance = Join-Path $PWD 'prototype\runtime\network-v5'
.\prototype\tools\Initialize-Network.ps1 -Directory $instance -Godot $godot `
  -Store $store -HostExecutable $gateway -WithBuilding
.\prototype\tools\Start-Network.ps1 -Directory $instance
.\prototype\tools\Start-NetworkClient.ps1 -Directory $instance -Profile editor-a
.\prototype\tools\Start-NetworkClient.ps1 -Directory $instance -Profile editor-b
```

初始化只对新目录运行一次，创建独立 SQLite 世界、私有会话配置和本机测试证书。已有 JSON 世界不会被覆盖。服务启动脚本先导入工程资源，保证全新目录中的中文字体和资源缓存可用。再次进入同一世界只执行 `Start-Network.ps1` 和客户端启动命令。

实例占用三个相邻端口：默认 **19550** 为内部 WebSocket，**19551** 为 HTTP，**19552** 为 HTTPS；均仅监听本机回环地址。初始化可用 `-Port 19650` 改变起始端口。不要让其他离线编辑器写入运行中的网络数据库。

`editor-a`、`editor-b` 是不同主体，共享区域所有者编辑授权；`observer` 只读；`guest` 使用独立所有者身份，不能修改演示区域所属对象。令牌有效期七天，单连接最长八小时。`private-config.json` 和 `localhost.pfx` 不得提交到仓库或分发给普通客户端。真实登录、身份库存和会话管理属于 V6。

## 3. 操作与提交

新版布局和完整操作见 [界面说明](network-interface.md)。

- 在场景页搜索对象或直接点选三维物体；属性页修改名称和 X/Y/Z，点击“保存对象修改”。双击列表对象或按 F 定位。“切换门 / 灯”提交交互状态；删除独立对象需要确认。
- 点击顶部“进入漫游”或在非文本输入状态按 Tab，WASD 移动、鼠标转向、空格跳跃，Esc 返回。漫游收起工具面板；连接或必要碰撞资产未准备完成时不能进入可操作状态。
- 组合、地形、环境等领域能力仍通过高级页命令和 JSON 参数操作，参数见 [领域接口](architecture-and-api.md)。当前没有共享撤销历史。
- GLB 选择后在资产页填写名称、许可和来源并提交；成功后选择模型并点击“将模型放到角色前方”。模型尺寸采用原始包围尺寸，后续可以在属性页修改位置；全部操作仍由服务器校验和保存。
- “等待服务器提交”不是成功。收到 SQLite 持久化回执后界面显示提交修订；竞争修改可能返回 `REVISION_CONFLICT`，应检查最新状态后重新提交。
- 若提交时断线，复制保留请求 ID，重新登录后在高级页使用“查询提交结果”。未知结果不能当作失败并随意换 ID 重复执行。下载的观察记录包含请求 ID 和结果，不包含会话令牌；它不是完整备份。

## 4. 浏览器客户端

下载官方 **Godot 4.5.1 export templates**，解开 `.tpz` 并取出 `templates/web_nothreads_release.zip`。使用单线程标准版模板，不能换成 .NET 或多线程模板。

```powershell
$webBuild = Join-Path $PWD 'prototype\build\network-web-v5'
.\prototype\tools\Export-NetworkWeb.ps1 -Godot $godot `
  -Template 'C:\Downloads\templates\web_nothreads_release.zip' -Destination $webBuild
```

导出会在新目录复制工程、重新导入、导出发布包并生成压缩文件；只有出现 `export-manifest.json` 才算完成。初始化新实例时添加 `-WebDirectory "$webBuild\web"`。已有实例则先停止服务，修改其 `private-config.json` 中的 `web_root` 为这个绝对路径，再重新启动。

本机可以打开 **http://127.0.0.1:19551/**，输入实例中的会话令牌后连接。回环 HTTP 是浏览器允许的本地可信上下文；该入口不对外部网络开放。桌面入口使用生成的 PEM 校验 HTTPS。HTTPS 浏览器入口为 **https://127.0.0.1:19552/**，使用本机自签名证书；浏览器需明确接受该实例的证书后才能使用。脚本不会安装系统根证书。正式部署应配置受信证书及反向代理，当前版本尚未验证公网部署。

Web 使用 WebGL2，固定采用顶点光照、关闭动态阴影和 MSAA 的轻量画面配置。页面关闭不影响权威区域。刷新或清除浏览器缓存后需要重新输入令牌；令牌仅在内存，未写入 localStorage、sessionStorage 或构建产物。切到后台停止移动输入，返回前台后请求快照。不同主体登录时释放旧投影和资产缓存。

## 5. 停止、备份与恢复

```powershell
.\prototype\tools\Stop-Network.ps1 -Directory $instance
```

停止脚本核对记录的进程 ID、可执行文件和启动时间，只结束这个实例的两个进程。客户端可单独关闭，服务继续运行。停止前等待正在提交的操作完成；若连接在提交中断开，重启后按原请求 ID 查询结果。进程终止测试不等价于断电保证。

使用 [RegionStore 备份/恢复流程](../../services/README.md#3-备份恢复与回滚) 导出一致的世界和资产。备份包不包含登录配置及历史网络回执；恢复到新实例产生新的网络世代，旧命令不能作为新世界的写入请求。原数据库目录原样恢复包含其持久回执。V5 将数据库迁移到 schema 3，旧程序不能打开唯一的已升级数据库；回滚使用升级前的备份。

## 6. 常见问题

| 现象 | 检查与处理 |
| --- | --- |
| 仍显示原离线编辑器 | 使用 `Start-NetworkClient.ps1`；`Start.cmd` 保留离线入口 |
| 服务未启动 | 查看实例内 `authority.log`、`gateway.stderr.log`；核对 ASP.NET Core 8、端口及程序路径 |
| 网页 404 或加载中断 | `web_root` 应指向含 `index.html` 的完整导出目录；确认构建清单已经生成 |
| 无法登录 | 核对令牌、有效期及服务地址；同一主体的新连接会替换旧连接 |
| 等待必要碰撞资产 | 查看提示；检查服务端资产及 SHA256，修复后点“重试资产” |
| `MAINTENANCE_REQUIRED` | 服务已冻结未知存储结果，或成功/失败回执达到上限；保留数据库与日志，停止写入后排查 |

当前上限是单区域、8 个会话和既有 16 个静态导入资产。两个客户端验收不能推出 8 个活跃用户、更大场景或公网条件下的性能保证。
