# 观盘 Pro Next — NAS 部署包

本目录是新原生 App 的独立 NAS 服务，不会连接、迁移或删除旧版数据库。NAS 宿主机映射端口为 `30001`，容器内服务端口仍为 `8786`（`30001:8786`），持久化数据使用当前项目目录对应的独立 Docker named volume。旧服务、旧端口和旧数据目录应保持不变。

## 包含内容

- `compose.yml`：独立容器、独立数据卷、健康检查和可配置绑定地址。
- `server/`：Python 标准库服务源码、Dockerfile 和单元测试。
- `server/web/`：与 iPhone 使用同一新账本的网页入口。
- 旧网页账本的一次性迁移暂存 API：只接收显式下载的快照并生成预览，不会自动写入新真实账本。

## 部署前

1. 将此包解压到 NAS 上新建的独立目录，建议目录名使用全小写 `guanpan-next`。Compose 已显式指定小写项目名 `guanpan-next`；若 NAS 部署器仍使用文件夹名作为项目名，请将解压目录重命名为 `guanpan-next`，不要用压缩包原名 `GuanpanPro-NAS-Deployment`。
2. 确认 NAS 宿主机的 `30001` 端口可用；容器内部服务端口固定为 `8786`。
3. 使用 NAS 的 Docker Compose 插件或命令在该目录启动：

   ```sh
   docker compose up -d --build
   docker compose ps
   docker compose logs --tail=100 guanpan-next
   ```

4. 浏览器打开 `http://NAS内网地址:30001/` 可查看、下载并编辑新账本 JSON。点击保存前必须勾选确认；写入使用 NAS 修订号比较，冲突时不会覆盖。iPhone 在“设置 → NAS 同步”下载该修订；页面的文件恢复也会经过同一套校验。
5. 验证本机健康状态：

   ```sh
   curl http://127.0.0.1:30001/health
   ```

   不需要应用口令。

## iPhone 连接方式

- 家庭局域网内 iPhone 可直连 `http://NAS内网地址:30001`；公网访问必须走 HTTPS 反向代理或 VPN，不要把无口令的明文 HTTP 服务直接暴露到公网。
- Docker 将 NAS 宿主机 `30001` 映射到容器 `8786`；iPhone、浏览器和其他容器外客户端都使用宿主机端口 `30001`。容器内健康检查继续访问 `127.0.0.1:8786`。
- `30001` 独立于旧服务端口（包括既有的 8072、8788、8789）。

## 数据和安全边界

- 新数据写入 Compose 项目专属的 Docker named volume，数据库路径在容器内为 `/data/guanpan-next.sqlite3`。请在部署时把项目目录命名为 `guanpan-next`，以便清晰区分新数据卷。
- NAS 不会连接或自动读取旧数据库。需要迁移时，由 iPhone 在设置中直接连接旧网页 `/api/data`，新 NAS 只把快照存入独立的迁移暂存表并生成预览；用户在手机上核对并确认后，才备份本机、导入真实账本并初始化新账本。ETF 每份历史派息事件一并保留；推算值不当作实际到账。旧账本现金/持仓迁入前不会写入真实账本，也不会删除旧目录。
- 更改配置前备份本 Compose 目录与新 volume。卸载时不要运行 `docker compose down -v`，除非已单独备份并明确决定删除新服务数据。
- 真实资产迁移必须经过单独备份、校验和用户确认；模拟账户与真实账本保持隔离。

## 运行证据与限制

- 服务端单元测试：本地 Linux 环境运行 `cd server && python3 -m unittest discover -s tests -v`。
- 历史回测：`POST /v1/backtests/{A-H}` 使用 NAS 已存日 K（缺档时尝试抓取并归档），运行结果分别存入实验记录；`GET /v1/backtests/runs/{runId}` 可重新读取。A 是现金对照；G 是明确标注的点时多因子代理信号，不是历史 DeepSeek 预测。所有成交只按下一交易日开盘日 K 估算，无法证明五档排队成交。
- NAS 私人顾问：`POST /v1/ai/analyze` 仅接受显式 `userConfirmed: true` 及单 ETF、最多 250 根 OHLC 日 K、当前持仓/目标比例、现金、该证券最多 30 笔流水、分红和目标等白名单研究上下文。使用 NAS 的 `DEEPSEEK_API_KEY`，不回传 key、不产生真实委托；无 key 时返回 503。iOS 会在发送前显示本次数据范围确认，并将输入快照与模型结论保存在本机决策记录。当前仅用 mock provider 测接口，尚未用真实 NAS key/DeepSeek 联调。
- 网页账本编辑：网页打开时读取 NAS 当前修订；编辑 JSON 并勾选确认后，使用 `expectedRevision` 写入新修订。修订冲突会拒绝覆盖；手机可再下载该修订。网页编辑入口不等于真实券商交易。
- 最近一次服务器结果：68 项 Python 测试通过（2026-10-20；含 mock DeepSeek、12 证券 AI 上下文和 G 日线部分撮合单测）。网页内联 JavaScript 语法和 Git 空白检查通过。此结果不代表 iOS 已编译或 NAS 已部署。
- iOS 分时图源码使用固定 09:30–15:00 交易时轴，午休有压缩间隔；全屏图表提供 NAS 历史日期选择与返回最新日，所选日/最近日随导航状态持久化，多日缓存只绘制所选交易日，不会把早盘样本拉伸到收盘或叠加不同日期。对应 XCTest 已写入但未运行。
- 日 K MA5/10/20/60/250 由日收盘价滚动计算并用同一结果拟合图表纵轴；默认打开所有均线，少于 250 根有效日 K 时保留入口并显示缺数说明。NAS 初始日 K 请求 640 根且本地档案按日期合并；对应均线 XCTest 仅写入源码，未在 Swift 工具链中运行。
- 当前开发工作区没有 Docker CLI，因此尚未验证镜像构建或 Compose 启动。
- 尚未部署到用户的 NAS，也未验证该 NAS 的反向代理、证书、外网/VPN 路径及真实 iPhone 连通性。交付的是可部署源码包，不代表 NAS 已上线。

## 三条独立通道与 DeepSeek

- 账本同步：网页和 iOS 可单独下载/上传新账本，写入采用修订号比较；不是自动覆盖。
- NAS 分时采集：独立线程在工作日交易时段每分钟抓取默认四只 ETF、已归档代码和 iPhone 已确认登记的自选代码，以证券代码和时间戳去重，永久留存于新 SQLite。每次采集还会核验同一时点的行情 IOPV；仅当数据源明确标为 ETF 且时间相差不超过 5 分钟时才写入该采样点。缺失的 IOPV 保持为空，后续原始分时拉取不会覆盖已验证的 IOPV。数据源失败不删除旧记录。iPhone 打开详情或新加自选时会登记代码；登记不涉及真实账本。
- NAS 日 K：独立线程每 30 分钟抓取腾讯前复权日 K；按交易日和代码合并归档，重叠日期允许上游修正，较短行情窗口不会删除更早历史。手机无网或 NAS 离线时，手机端原有本地日 K 缓存仍可读。
- NAS 收息与研究：独立分红采集线每日读取 ETF 的 Eastmoney F10 分红档案（登记日、除息日、每 10 份金额、发放日），个股则读取已实施的股票分红公告；并对比前复权/原始日 K 的因子变化。公告历史与价格调整推算值明确分开，推算值标为估算，采集更新采用保留历史合并，不会因某轮源缺失清空已有事件。收息事件仅作历史研究，不自动增加真实现金；个人实际到账需由用户根据券商流水记录并确认。另一条独立研究线每 15 分钟检查已归档日 K；当至少 250 个有效交易日可用时保存可追溯的本地因子。若设置了 `DEEPSEEK_API_KEY`，每只证券每个完成的交易日最多保存一份 DeepSeek 解读；未设 key 时不调用外部模型。研究只读取经过校验的日 K 因子，不接触券商交易。

访问 `/health` 会返回后台线最近一次状态：`daily-archive`、`minute-archive`、`dividend-research`、`factor-research` 和 `g-live-simulation`，并附带 `ageSeconds`、`stale` 与计算后的 `health`；另有不包含密钥的 `aiProvider` 配置状态。超过 40 分钟没有心跳会显示 `health: stale`，避免把容器存储的旧 `ok` 误看成当前正常。`degraded` 表示本轮部分数据源失败，但已归档的数据不会被删除；`idle` 表示当前无需运行。

### G：NAS 自主模拟第一阶段（源码已编码，尚未实际部署联调）

- `POST /v1/simulations/G` 必须带 `userConfirmed: true` 和 `expectedRevision`。`action: "start"` 需要 `config`，包含 `initialCash`、证券 `codes`、每只证券已核验 `lotSizes`、逐证券 `feesPerFill` 与 `weights`。每只 ETF 的固定成交费用可配置为 ¥0.10；股票费用可独立配置。该 API 不支持、也不调用券商委托。
- 暂停、恢复、资金追加/撤回、确认重置均写入虚拟账户专属表，并保存修订快照；重置历史仍保留在版本历史表。
- iOS 量化实验室现在有 NAS G 状态读取、启动、暂停/恢复、虚拟资金追加/撤回和重置入口；启动证券来自已核验的自选 ETF，按等权设初始参考配置。此 SwiftUI 改动尚未由 Xcode 编译或运行验证。
- 工作日收盘后，worker 要求所有配置证券具有同一个当日完整日 K、每只证券至少 250 根日 K，以及可用 DeepSeek API key。DeepSeek 必须返回通过日期、代码、权重、风险和失效条件校验的 JSON；无 key、过期数据或响应无效时不生成新指令。
- 次日或下一个可用归档交易日，以真实归档日 K 开盘价执行前一天的虚拟意图，现金不足时能部分买入并保留剩余数量到后续可用交易日。卖出先于买入释放模拟现金。记录明确写明 `archived daily open proxy; no orderbook or queue evidence`，不是交易所队列或保证成交。每日日终记录权益、NAV、回撤、AI 运行状态和审计信息；即使当天 AI 失败，也会保留旧委托的日 K 结算和当日净值，但不会创建新订单。
- 本地 68 项测试覆盖结构校验、DeepSeek mock、最多 12 证券的紧凑历史上下文、虚拟资金账户、修订冲突、开盘代理撮合、部分成交续单与真实账本隔离；尚未用真实 key 调用 DeepSeek，也未在 NAS 持续运行。历史回测中的 G 仍是多因子历史代理，两者不能混称。

在 NAS 新项目目录复制 `.env.example` 为 `.env`，填入 NAS 后台研究使用的 `DEEPSEEK_API_KEY`，选择 `GUANPAN_AI_PROFILE=flash` 或 `pro`。也可用 `custom` 配置 OpenAI 兼容 HTTPS 服务的 `GUANPAN_AI_BASE_URL` 和 `GUANPAN_AI_MODEL`。不要把 NAS key 提交到 Git 或发到网页。iOS 另有可选的手机端 key 输入：保存在本机 Keychain，仅在用户明确发起 ETF 分析时直连模型；不上传 NAS、不进入账本/备份。NAS key 与 iPhone key 是两份独立配置。预置模型名为 `deepseek-v4-flash`（flash 档案）与 `deepseek-v4-pro`（pro 档案）。**注意：旧的 `deepseek-chat` / `deepseek-reasoner` 已于 2026-07-24 停用；写成 `deepseek-flash`（缺 v4-）会直接 400 Model Not Exist。**

填入 key 后重建/重启容器，再手动运行一次连通性检查：

```sh
docker compose up -d --build
docker compose exec guanpan-next python check_ai.py
```

检查只发送一条“Reply with OK only”探针，不发送持仓或行情，不会在容器启动时自动调用；DeepSeek 可能按服务商规则计费。返回 `verified` 才表示该 NAS 容器的 key、模型和网络请求已真实验证。`configured_unverified` 只表示环境变量非空，不能证明 key 有效。`/v1/research/{代码}` 也只返回不含 key 的配置状态。AI 解读任务仍基于已归档的单只证券日 K 因子，会把该数据发给 DeepSeek。

也可以在网页「研究 / AI」区块点 **验证 AI**，或直接请求：

```sh
curl http://127.0.0.1:8786/v1/ai/verify
# 通了：{"state":"verified","model":"deepseek-v4-flash",...}
# 没配 key：503 {"state":"unavailable","error":"NAS 尚未配置 DeepSeek API key"}
```

`/health` 的 `aiProvider.state` 也是同一口径：`missing_key` / `invalid_profile` / `configured_unverified` / `verified`。

这四条线程互不依赖账本同步开关；当前仍缺 NAS 真机部署与 DeepSeek 实际凭据测试。

## 账本备份版本：可列出、可删除

NAS 每次接受一次账本写入（`POST /v1/real/books/main`）都会在 `real_book_history` 留一份**完整版本**，用于回滚与核对。

| 操作 | 接口 |
|---|---|
| 列出版本（只含元数据） | `GET /v1/real/books/main/history` |
| 取某个版本的完整账本 | `GET /v1/real/books/main/history/{revision}` |
| 删除某个历史版本 | `DELETE /v1/real/books/main/history/{revision}` |
| 只保留最近 N 个 | `DELETE /v1/real/books/main/history?keep=20` |

规则：**当前生效版本不允许删除**（服务端返回 409），因为它是回滚锚点；删除只影响 NAS 上的历史副本，不动手机账本。iOS 的「资产 → 备份与恢复 → NAS 备份版本」里可以逐条删或一键只留最近 20 个。

## 手机与 NAS 联通：三条同步线（对应你说的三种线）

部署并启动后，iPhone 在「设置 → 新 NAS 连接」填入 `http://NAS内网地址:30001`（公网必须走 HTTPS 反向代理/VPN，不要把无口令明文 HTTP 暴露公网），即可打通以下三条**相互独立、互不依赖**的通道：

1. **可开关的交易流水 / 持仓线（账本同步）**：iOS 与网页共用同一份新账本，写入走修订号比较，不会自动覆盖。总开关在 iOS 设置里的「自动同步」（`automaticKey`）；网页把自选/持仓写回 NAS 还需 `uploadKey`。冲突时停止并提示，不静默覆盖。
2. **独立的 NAS 自动收集分时数据线**：`minute-archive` + `daily-archive` 后台线程，盘中每分钟、闭市每 10 分钟抓腾讯字段（含 IOPV）写入 `/v1/market/*`，与 App 是否在前台无关。手机回前台/启动会拉 `/api/market/archive` 合并；缺失的 IOPV 保持为空，不会被后续原始分时拉取覆盖。
3. **独立的后台自动模拟线**：`g-live-simulation`（G 日终虚拟撮合）+ `dividend-research` / `factor-research`（分红与因子研究）后台线程；需设置 `DEEPSEEK_API_KEY` 才生成 AI 解读。该线只读已校验的日 K 因子，不碰真实账本、不下单。

### 重要：镜像必须带 tzdata（连不上的首要原因）

`python:3.12-slim` 基础镜像默认没有时区数据，`ZoneInfo("Asia/Shanghai")` 会在服务导入阶段直接抛错，导致**容器启动即崩、手机/网页全部连不上**（表现为 `/health` 无响应）。本包 Dockerfile 已加 `RUN pip install --no-cache-dir tzdata`。若你之前构建过旧镜像，请用下面命令**重建**（带 `--no-cache` 最稳）：

```sh
docker compose up -d --build --no-cache
docker compose logs --tail=100 guanpan-next
```

连通自检：`curl http://127.0.0.1:30001/health` 应返回 `workers` 五条线程状态与 `aiProvider`；若仍连不上，先看上面日志——多半是 tzdata 未装导致启动即退出，按本段重建即可。
