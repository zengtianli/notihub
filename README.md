# Notihub · 通知复盘

**中文** | [English](README_EN.md)

Notihub 把 Mac 通知整理成可搜索的时间线、随手记、待办与每日复盘。Mac 原生界面和采集器共享数据引擎；移动客户端按日期读取同一份云端记录。

这是 MIT 源码快照，没有安装包、真实用户内容、账户、设备标识、证书、部署配置或私有提交历史。`mac/` 是 SwiftUI 界面，`cli/` 是采集与本机数据引擎，`ios/` 保留 iPhone、iPad、Watch、Vision 的源码及工程描述，`service/` 提供可自建的 FastAPI 核心。

## 从源码验证

需要 macOS、Swift 工具链（Mac 包要求 Swift 6）和 Python 3.10 以上。所有 Swift 包只用系统框架，不下载第三方包。

```sh
cd cli
swift build -j 4
swift test -j 4
NOTIFHUB_DATA_DIR="$PWD/.test-data" .build/debug/notifhub selftest
cd ../mac
swift build -j 4
swift test -j 4
cd ../ios
swift build -j 4
swift test -j 4
```

移动端的 Swift 包验证生产核心契约，完整 App 用 XcodeGen 根据 `ios/project.yml` 生成工程，再在 Xcode 选择自己的开发团队、服务地址和目标。源码快照没有签名、公证、App Store 或 TestFlight 发行。不要覆盖作者签名的安装版；首次采集、Apple 数据读取及写入提醒事项涉及系统权限，应由使用者在自己的机器上授权。

```sh
cd service
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
.venv/bin/python smoke.py
.venv/bin/python -m unittest discover -s tests
```

`smoke.py` 用临时数据库、运行时随机凭据和回环端口启动真实 HTTP 服务，调用健康接口后关闭；不读个人库、不转发推送。服务的两份测试可分进程并行：分别运行 `python -m unittest discover -s tests -p test_runtime.py` 与 `-p test_bark.py`。

## 配置与隐私

云端同步需要自建服务。后端 `create_app()` 读取 `NOTIFHUB_ID`、`NOTIFHUB_URL`、`NOTIFHUB_DATABASE`、`NOTIFHUB_SYNC_TOKEN_FILE`、`NOTIFHUB_PROXY_TOKEN_FILE`；两份随机密钥必须各至少 32 字符、彼此不同，并以 0600 文件放在源码树外。生产服务仅绑定回环地址，由使用者部署 HTTPS 和认证反向代理。代理必须覆盖而非转发客户端的 `X-Notifhub-Proxy`；浏览器端仍需自建兼容 `/_gate/api/login` 的会话认证。原生 `/native/api/` 接口独立验证 Bearer 凭据。

移动端的 `NotihubServiceURL`（Info.plist；XcodeGen 中为示例地址）或启动环境 `NOTIHUB_SERVICE_URL` 指定 HTTPS 站点；登录与数据请求使用同一个站点。默认 `.invalid` 地址不会连接作者服务。登录密码仅存 Keychain；源码快照停用了通过启动参数自动喂密码。

Mac/CLI 保留原配置入口 `~/.config/notifhub/` 和数据路径 `~/.local/share/notifhub/`。`NOTIFHUB_CONFIG` 与 `NOTIFHUB_DATA_DIR` 可用于隔离测试；不得把数据目录加入源码。云连接配置是源码树外的 `cloud-<实例ID>.json`（`id`、`url`、`token`），HTTPS 域名必须匹配当前实例的 `siteURL`。配置形状见 `examples/`，其中全是无法使用的示例值。

静态上传和远程接单须自行设置 `NOTIHUB_UPLOAD_HOST`，未配置时拒绝访问远端；可选 `NOTIHUB_REMOTE_DIR`、`NOTIHUB_SITE_URL`、`NOTIHUB_QUEUE_URL` 控制独立目标。云同步另走 `notihub sync`。上传需要显式 `--upload`；默认只在本地生成。

AI 总结是可选适配入口：自行提供 `NOTIHUB_LLM_CLIENT_DIR` 指向包含 `tools.llm_client.chat` 的 Python 包，或将 `summary.enabled` 设为 `false`。适配器接收 `system`、`message`、`provider`、`timeout`、`origin` 参数并返回文本；本快照不包含作者的模型订阅封装。启用总结会把当天内容发送到使用者选择的模型服务。`NOTIHUB_REMAIN_SCANNER` 是可选外部扫描器；作者的工作台/交接扫描器没有包含在快照中。AI 会话收集读取使用者自己的 Claude/Codex 日志，配置中可关闭 `ai.enabled`。

Mac 更新清单由 `NOTIHUB_UPDATE_MANIFEST_URL` 配置，默认示例地址；移动端明确标为未发行。本快照不沿用作者的私有更新渠道。可选 Bark 转发凭据通过服务环境文件配置，默认关闭；没有短信或邮件发送通道。

所有演示内容与测试库由代码合成。历史真实短信样本已换成虚构文本，没有截图或用户导出数据。编译与隔离测试不证明真实采集权限、设备使用、反向代理部署或线上同步已通过。

## 许可

原创代码与图标采用 [MIT](LICENSE)。依赖说明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。`snapshot-manifest.json` 记录源码提交与文件哈希。
