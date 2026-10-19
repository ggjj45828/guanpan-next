# 观盘 Pro Next — NAS 部署包

本目录是新原生 App 的独立 NAS 服务，不会连接、迁移或删除旧版数据库。NAS 映射端口固定为 `8786`，持久化数据使用当前项目目录对应的独立 Docker named volume。旧服务、旧端口和旧数据目录应保持不变。

## 包含内容

- `compose.yml`：独立容器、独立数据卷、健康检查和可配置绑定地址。
- `server/`：Python 标准库服务源码、Dockerfile 和单元测试。
- `server/web/`：与 iPhone 使用同一新账本的网页入口。

## 部署前

1. 将此包解压到 NAS 上新建的独立目录，建议目录名使用全小写 `guanpan-next`。Compose 已显式指定小写项目名 `guanpan-next`；若 NAS 部署器仍使用文件夹名作为项目名，请将解压目录重命名为 `guanpan-next`，不要用压缩包原名 `GuanpanPro-NAS-Deployment`。
2. 确认 NAS 的 `8786` 端口未被占用。若端口被占用，先在 NAS 上释放该端口；容器内部服务端口固定为 `8786`。
3. 使用 NAS 的 Docker Compose 插件或命令在该目录启动：

   ```sh
   docker compose up -d --build
   docker compose ps
   docker compose logs --tail=100 guanpan-next
   ```

4. 验证本机健康状态：

   ```sh
   curl http://127.0.0.1:8786/health
   ```

   不需要应用口令。浏览器打开 `http://NAS地址:8786/` 可查看、下载和经确认恢复新账本。

## iPhone 连接方式

- 仅限受信任的家庭局域网或 VPN；iPhone 目前要求可信 HTTPS 入口。无应用口令的服务不得通过无身份保护的公网代理开放。服务端口为内网 HTTP；不要将明文 HTTP 直接暴露到公网。
- `8786` 会绑定 NAS 网络接口，以便同一 LAN/VPN 内的 iPhone 或反向代理访问。请用 NAS 防火墙限制来源；互联网访问必须经 HTTPS 代理/VPN。
- 该端口独立于旧服务端口（包括既有的 8072、8788、8789）。

## 数据和安全边界

- 新数据写入 Compose 项目专属的 Docker named volume，数据库路径在容器内为 `/data/guanpan-next.sqlite3`。请在部署时把项目目录命名为 `guanpan-next`，以便清晰区分新数据卷。
- 该服务不读取旧系统账本，不执行旧数据导入，不删除旧目录，也不自动启用真实资产账本。
- 更改配置前备份本 Compose 目录与新 volume。卸载时不要运行 `docker compose down -v`，除非已单独备份并明确决定删除新服务数据。
- 真实资产迁移必须经过单独备份、校验和用户确认；模拟账户与真实账本保持隔离。

## 运行证据与限制

- 服务端单元测试：本地 Linux 环境运行 `cd server && python3 -m unittest discover -s tests -v`。
- 当前开发工作区没有 Docker CLI，因此尚未验证镜像构建或 Compose 启动。
- 尚未部署到用户的 NAS，也未验证该 NAS 的反向代理、证书、外网/VPN 路径及真实 iPhone 连通性。交付的是可部署源码包，不代表 NAS 已上线。

## 三条独立通道与 DeepSeek

- 账本同步：网页和 iOS 可单独下载/上传新账本，写入采用修订号比较；不是自动覆盖。
- NAS 分时采集：独立线程在工作日交易时段每分钟抓取默认四只 ETF、已归档代码和 iPhone 已确认登记的自选代码，以证券代码和时间戳去重，永久留存于新 SQLite。每次采集还会核验同一时点的行情 IOPV；仅当数据源明确标为 ETF 且时间相差不超过 5 分钟时才写入该采样点。缺失的 IOPV 保持为空，后续原始分时拉取不会覆盖已验证的 IOPV。数据源失败不删除旧记录。iPhone 打开详情或新加自选时会登记代码；登记不涉及真实账本。
- NAS 研究：独立线程每 15 分钟检查已归档日 K；当至少 250 个有效交易日可用时保存可追溯的本地因子。若设置了 `DEEPSEEK_API_KEY`，每只证券每个完成的交易日最多保存一份 DeepSeek 解读；未设 key 时不调用外部模型。研究只读取经过校验的日 K 因子，不接触券商交易。

访问 `/health` 会返回三条后台线最近一次状态：`daily-archive`、`minute-archive` 和 `factor-research`。`degraded` 表示本轮部分数据源失败，但已归档的数据不会被删除；`idle` 表示不在分时采集时段。

在 NAS 新项目目录创建 `.env`，可选设置自己的 `DEEPSEEK_API_KEY` 和 `GUANPAN_AI_PROFILE=flash` 或 `pro`。预置官方 HTTPS 地址与 `deepseek-flash`、`deepseek-v4-pro`；`custom` 模式使用 `GUANPAN_AI_BASE_URL` 和 `GUANPAN_AI_MODEL`。不要把 key 提交到 Git 或交给 iPhone。模型调用会产生第三方费用，并将该只证券的日 K 因子发送给 DeepSeek。

这三条线程互不依赖账本同步开关；当前仍缺 NAS 真机部署与 DeepSeek 实际凭据测试。
