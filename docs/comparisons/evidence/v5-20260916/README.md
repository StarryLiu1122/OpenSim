# V5 原始验收证据（2026-09-16）

本目录保存声明对应的最终报告、实际截图和构建摘要。Web 总结果为失败，原因是 Firefox 冷启动超过 10 秒；75 个断言通过，1 个性能断言失败，`suite completion` 是其汇总错误，不重复计为第二个独立缺陷。报告未删除该失败。

- native-report / ui-report：191 项原生、66 项离线界面。
- network-data-report：16 项网络数据合同。
- store-report：53 项真实 SQLite 进程测试。
- network-report：64 项权威区域与真实双桌面检查。
- web-report：54 项浏览器功能断言、20 项冷启动就绪/脚本检查、1 项样本数量检查通过；两内核各 5 次冷启动及各 1 次热启动。
- desktop-a/b、chromium、firefox：实际客户端截图；令牌控件掩码显示。
- hardware、构建及导出清单：运行环境与输入追溯。
- deployment-report：11 项正式启动入口检查，包括双窗口认证、停止和原目录重启。
- package-manifest：离线安装实际校验的 428 个文件；包含打包时的文档快照，后续验收说明单独更新。

浏览器后台用例的原生窗口最小化与 Playwright 确定性帧暂停分别记录，未伪称自动化浏览器产生了真实 `document.hidden=true`。HTTPS 自签证书的浏览器忽略范围仅限临时测试上下文；桌面和原生 HTTPS 下载另行验证指定 PEM。

原始报告可能含本机测试路径及随机测试 UUID，不含会话令牌、私钥、用户存档或运行数据库。manifest.json 为本目录文件摘要。完整方法、限制和复现命令见 [V5 验收记录](../../v5-completion.md)。
