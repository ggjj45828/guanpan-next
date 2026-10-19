# 观盘 Pro · 全新 iOS 原生工程

本工程与旧版 UI、数据库和运行服务隔离。仅覆盖场内证券账本；旧账本不会自动导入，真实资产变更写入独立审计文件，模拟账户另行保存，不连接券商。

## 正式设计规范

用户已确认方向 A「东方编辑室」为全局设计语言，方向 B「精密交易台」的信息密度只用于行情、五档盘口、图表、量化实验室和流水。完整产品与视觉规范见 `PRODUCT_REDESIGN_REVIEW.md`。先前 HTML/SVG 是探索稿，不代表原生功能，也不作为交付验收证据。

## 原生实现结构

- `ios/Sources/GuanpanNextApp.swift`：五个原生主页面、原生 `TabView` / `NavigationStack`、证券详情、AI 研究、数字孪生、资产、搜索、通知、设置和安全流程。
- `ios/Sources/DesignSystem.swift`：浅色/深色/护眼主题、编辑式层级、专业数据面板、状态和动作组件。
- `ios/Sources/UnifiedChartView.swift`：统一图表视图；价格独立主轴、IOPV 溢折价独立副轴、成本线不改变纵轴范围，原始时间戳控制横轴。
- `ios/Sources/NextAppModel.swift`：独立本机账本/模拟/偏好/缓存/决策历史文件及审计入口；损坏文件会保留并阻断覆盖，只有校验通过的恢复流程才能重建；交易规则、缓存与数据源未验证时不提供伪数据。
- `ios/Sources/MarketDataService.swift`：手动刷新腾讯报价和当日分时。来源、响应代码、价格、源时间均核验；不伪造 IOPV、盘口或缺失历史。解析审查记录见 `MarketDataProvenance.md`。
- `ios/Sources/NextCore.swift`：场内账本、行情质量、审核交易规则、五档盘口、模拟撮合、决策证据、A–G 数字孪生及额外 H 用户自定义策略。
- `ios/Tests/NextCoreTests.swift`：账本、规则、图表、盘口撮合、策略隔离和恢复相关核心测试。
- `ios/UITests/NativeNavigationTests.swift`：五大主页面、证券详情、全屏图表、AI 深链、设置导航及模拟器截图附件。
- `../.github/workflows/guanpan-next-ios.yml`：macOS 上的 Swift/Xcode 构建、单元/UI 测试和 `.xcresult` 证据包流程。
- `server/`：新 NAS 服务，独立数据库/端口，含只读 Tencent 行情代理和 CAS 真实账本快照端点；尚未部署。NAS 不要求应用口令；网页可读取和下载新账本，iOS 经确认后可双向传输真实账本，修订冲突停止覆盖。
- NAS 的 8790 容器端口是服务内部 HTTP；不要直接暴露互联网或向 iPhone 明文发送账本令牌。正式连接须经可信 HTTPS 反向代理/VPN TLS 入口。

## 当前验证边界

服务器已有 17 项 Python 测试通过。此执行环境未安装 Xcode/Swift，因此尚无原生构建、模拟器截图、IPA 或真机手势验证。CI 中的构建与 UI 测试配置已经加入，但未在 GitHub Actions 上运行；不能将工作流配置视为成功证据。

目前 iOS 行情仅接入可选的腾讯报价和当日分时；历史 K 线、历史 IOPV、五档盘口、经核实的交易规则未接入。NAS 个人账本手动同步客户端和行情代理接口已编码，仍需实 NAS 部署/HTTPS/冲突实测；自动采集通道、在线 AI 研究与策略执行、真实推送、策略历史收益、性能及 iPhone Air 实机验证尚未完成。任何界面中的缺失数据都需明确提示，不能以静态示例数值冒充已连接功能。

日 K：NAS 每 30 分钟刷新默认四只 ETF 及已有缓存代码，原始腾讯前复权 OHLCV 写入独立 SQLite；来源不可用时保留已核验缓存。iPhone 日 K 周期读取 NAS 历史数据并在本机缓存。
