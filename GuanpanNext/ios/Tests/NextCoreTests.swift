import XCTest
@testable import GuanpanNextCore

final class NextCoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1792375200)
    func quote(time: Date, price: Decimal = 1.4) -> NextQuote {
        NextQuote(code: "159941", name: "纳指ETF", price: price, previousClose: 1.4, time: time, source: "test")
    }
    func etfRules(_ code: String = "159941", settlement: NextSettlementRule = .t0, assetClass: NextAssetClass = .etf) -> NextInstrumentRules {
        NextInstrumentRules(code: code, market: "SZ", assetClass: assetClass, settlement: settlement, lotSize: 100, feePerTrade: Decimal(string: "0.10"), source: "verified test fixture", verifiedAt: now)
    }
    func testIncomeAndDividendDataRoundTripsAndDoesNotRequireOldBookKeys() throws {
        let planned = NextIncomeEvent(kind: .etfDistribution, code: "563020", name: "红利ETF",
            exDate: now, payDate: now.addingTimeInterval(86400), units: 100,
            perUnit: Decimal(string: "0.012"), grossAmount: Decimal(string: "1.20")!, tax: Decimal(string: "0.10")!)
        try planned.validate()
        var book = NextBook(cash: 50, incomeEvents: [planned],
            dividendEvents: [NextETFDividendEvent(code: "563020", date: "2026-06-10", amountPerShare: Decimal(string: "0.012")!,
                isEstimated: false, recordDate: "2026-06-09", payDate: "2026-06-15")])
        let encoded = try JSONEncoder().encode(book)
        let decoded = try JSONDecoder().decode(NextBook.self, from: encoded)
        XCTAssertEqual(decoded.incomeEvents.first?.netAmount, Decimal(string: "1.10"))
        XCTAssertEqual(decoded.dividendEvents.count, 1)
        XCTAssertEqual(decoded.dividendEvents[0].recordDate, "2026-06-09")
        XCTAssertEqual(decoded.dividendEvents[0].payDate, "2026-06-15")
        XCTAssertNoThrow(try decoded.validate())
        let old = "{\"schemaVersion\":1,\"id\":\"\(UUID().uuidString)\",\"cash\":0,\"positions\":[],\"fills\":[],\"history\":[]}"
        XCTAssertNoThrow(try JSONDecoder().decode(NextBook.self, from: Data(old.utf8)))
        book.incomeEvents[0].tax = Decimal(string: "2.00")!
        XCTAssertThrowsError(try book.incomeEvents[0].validate())
    }
    func testBookRejectsMalformedFillAndHistoryValuesBeforeBackup() throws {
        let malformedFill = NextFill(date: now, code: "159941", side: "purchase", units: 100,
                                     price: 1.2, fee: 0.1, realized: 0)
        XCTAssertThrowsError(try NextBook(fills: [malformedFill]).validate())
        let malformedPoint = NextAssetPoint(date: now, total: -1, externalFlow: 0)
        XCTAssertThrowsError(try NextBook(history: [malformedPoint]).validate())
        let validFill = NextFill(date: now, code: "159941", side: "buy", units: 100,
                                 price: 1.2, fee: 0.1, realized: 0)
        XCTAssertNoThrow(try NextBook(fills: [validFill]).validate())
    }
    func testVerifiedDividendFallbacksRemainHistoricalAndEstimatedEventsAreSeparate() {
        let events = NextDividendAnalytics.merged([
            NextETFDividendEvent(code: "159545", date: "2026-05-15", amountPerShare: Decimal(string: "0.014")!, isEstimated: true),
            NextETFDividendEvent(code: "159941", date: "2026-05-15", amountPerShare: Decimal(string: "0.100")!)
        ])
        XCTAssertTrue(events.contains { $0.code == "159545" && $0.isEstimated == true })
        XCTAssertTrue(events.contains { $0.code == "159941" && $0.date == "2026-05-15" })
        XCTAssertTrue(events.contains { $0.code == "563020" && $0.isEstimated != true })
    }

    func testMissingQuoteDoesNotPretendAssetTotal() {
        var book = NextBook(); book.cash = 100
        book.positions = [NextPosition(code: "159941", name: "纳指ETF", units: 100, bookCost: 120)]
        XCTAssertNil(book.total(using: [:]))
        XCTAssertEqual(book.total(using: ["159941": quote(time: now)]), 240)
        XCTAssertEqual(book.positions[0].costPerUnit, 1.2)
    }
    func testDailyAssetChangeRequiresCompleteFreshQuotes() {
        var book = NextBook(); book.cash = 100
        book.positions = [NextPosition(code: "159941", name: "纳指ETF", units: 100, bookCost: 120)]
        let fresh = quote(time: now, price: 1.5)
        let stamp = NextDataStamp(source: "test", observedAt: now, quality: .live, detail: "")
        let value = book.valuation(using: ["159941": NextCachedQuote(quote: fresh, stamp: stamp)], at: now)
        XCTAssertEqual(value.total, 250)
        XCTAssertEqual(value.dailyChange, 10)
        XCTAssertEqual(NSDecimalNumber(decimal: value.dailyChangePercent ?? 0).doubleValue, 4.1666666667, accuracy: 0.000001)
        let stale = quote(time: now.addingTimeInterval(-3600), price: 1.5)
        let oldStamp = NextDataStamp(source: "test", observedAt: stale.time, quality: .cached, detail: "")
        XCTAssertNil(book.valuation(using: ["159941": NextCachedQuote(quote: stale, stamp: oldStamp)], at: now).dailyChange)
    }
    func testOnlineQuoteCacheLabelAgesWithoutAnotherNetworkRequest() {
        let observed = now.addingTimeInterval(-3600)
        let stamp = NextDataStamp(source: "feed", observedAt: observed, quality: .live, detail: "")
        XCTAssertTrue(stamp.label(now: now).contains("缓存"))
        XCTAssertTrue(stamp.label(now: now).contains("60 分钟前"))
    }
    func testBudgetDoesNotDependOnRealCashOrMutateBook() throws {
        let book = NextBook(); let goal = NextGoal()
        let result = try NextResearch.prepare(book: book, goal: goal, quotes: [:], now: now)
        XCTAssertEqual(result.options.count, 2)
        XCTAssertEqual(book.cash, 0)
        XCTAssertEqual(result.origin, "本地规则检查")
    }
    func testModelEvidenceMustExistAndDescribeTradeoff() throws {
        let result = try NextResearch.prepare(book: NextBook(), goal: NextGoal(), quotes: [:], now: now)
        XCTAssertEqual(try NextResearch.acceptModelOptions(result.options, evidence: result.evidence).count, 2)
        let fake = NextOption(id: "fake", title: "方案", rationale: "理由", tradeoff: "未知", evidenceIDs: ["invented"])
        XCTAssertThrowsError(try NextResearch.acceptModelOptions([fake, result.options[0]], evidence: result.evidence))
    }
    func testDecimalFeesReservationAndCancellation() throws {
        var sim = NextExperiment()
        try sim.place(code: "159941", limit: 1.5, units: 100, rules: etfRules(), at: now, until: now.addingTimeInterval(3600))
        XCTAssertEqual(sim.available, Decimal(string: "9849.90"))
        sim.cancel(sim.orders[0].id)
        XCTAssertEqual(sim.available, 10000)
    }
    func testNoFillFromOldFuturePreorderOrClosedSession() throws {
        var sim = NextExperiment()
        try sim.place(code: "159941", limit: 1.5, units: 100, rules: etfRules(), at: now, until: now.addingTimeInterval(3600))
        for stamp in [now.addingTimeInterval(-1000), now, now.addingTimeInterval(60)] {
            sim.observe(quote(time: stamp), now: now, marketOpen: true)
        }
        sim.observe(quote(time: now.addingTimeInterval(1)), now: now.addingTimeInterval(1), marketOpen: false)
        XCTAssertEqual(sim.cash, 10000)
        XCTAssertTrue(sim.positions.isEmpty)
    }
    func testFillOncePaysLimitAndFee() throws {
        var sim = NextExperiment()
        try sim.place(code: "159941", limit: 1.5, units: 100, rules: etfRules(), at: now, until: now.addingTimeInterval(3600))
        let stamp = now.addingTimeInterval(1)
        let bidPrices = ["1.39", "1.38", "1.37", "1.36", "1.35"]
        let askPrices = ["1.40", "1.41", "1.42", "1.43", "1.44"]
        let book = NextOrderBookSnapshot(code: "159941", observedAt: stamp, source: "test", bids: bidPrices.map { NextBookLevel(price: Decimal(string: $0)!, units: 100) }, asks: askPrices.map { NextBookLevel(price: Decimal(string: $0)!, units: 100) })
        try sim.observe(book, rules: etfRules(), now: stamp, marketOpen: true)
        let copy = sim
        try sim.observe(book, rules: etfRules(), now: stamp, marketOpen: true)
        XCTAssertEqual(sim, copy)
        XCTAssertEqual(sim.cash, Decimal(string: "9859.90"))
        XCTAssertEqual(sim.positions[0].bookCost, Decimal(string: "140.10"))
        XCTAssertEqual(sim.orders[0].averageFillPrice, Decimal(string: "1.40"))
    }
    func testInvalidOrderAndOverspendRejected() throws {
        var sim = NextExperiment(); sim.cash = 200
        XCTAssertThrowsError(try sim.place(code: "159941", limit: 1, units: 99, rules: etfRules(), at: now, until: now.addingTimeInterval(60)))
        XCTAssertThrowsError(try sim.place(code: "600000", limit: 1, units: 100, rules: etfRules("600000", assetClass: .equity), at: now, until: now.addingTimeInterval(60)))
        try sim.place(code: "159941", limit: 1.5, units: 100, rules: etfRules(), at: now, until: now.addingTimeInterval(60))
        XCTAssertThrowsError(try sim.place(code: "159941", limit: 1.5, units: 100, rules: etfRules(), at: now, until: now.addingTimeInterval(60)))
        sim.expire(at: now.addingTimeInterval(60))
        XCTAssertEqual(sim.available, 200)
    }
    func testBookAndSimulationIndependentRoundTrips() throws {
        let book = NextBook(), sim = NextExperiment()
        XCTAssertEqual(try JSONDecoder().decode(NextBook.self, from: JSONEncoder().encode(book)), book)
        XCTAssertEqual(try JSONDecoder().decode(NextExperiment.self, from: JSONEncoder().encode(sim)), sim)
    }
    func testPatientBuyAnalysisRequiresFreshQuoteAndCitedPriceResearch() throws {
        var book = NextBook(); book.cash = 0
        var goal = NextGoal(); goal.monthlyBudget = 1000
        let facts = [NextEvidence(id: "range-source", title: "估值区间", detail: "样例依据", level: "事实", observedAt: now)]
        let range = NextPriceResearch(lower: 1.4, upper: 1.6, evidenceIDs: ["range-source"], observedAt: now)
        let missing = try NextBuyOpportunity.prepare(code: "159941", book: book, goal: goal, quote: nil, research: range, rules: etfRules(), evidence: facts, now: now)
        XCTAssertFalse(missing.canSavePlan)
        XCTAssertTrue(missing.limitSteps.isEmpty)
        let q = quote(time: now)
        let stale = NextCachedQuote(quote: q, stamp: NextDataStamp(source: "cache", observedAt: now.addingTimeInterval(-900), quality: .stale, detail: "old"))
        let staleResult = try NextBuyOpportunity.prepare(code: q.code, book: book, goal: goal, quote: stale, research: range, rules: etfRules(), evidence: facts, now: now)
        XCTAssertFalse(staleResult.canSavePlan)
        let live = NextCachedQuote(quote: q, stamp: NextDataStamp(source: "licensed:feed", observedAt: now, quality: .live, detail: ""))
        let plan = try NextBuyOpportunity.prepare(code: q.code, book: book, goal: goal, quote: live, research: range, rules: etfRules(), evidence: facts, now: now)
        XCTAssertTrue(plan.canSavePlan, plan.riskSummary)
        XCTAssertEqual(plan.limitSteps.count, 2, plan.riskSummary)
        XCTAssertEqual(plan.limitSteps[0].fee, Decimal(string: "0.10"))
        XCTAssertEqual(book.cash, 0, "planning never spends the real ledger")
        let unverified = try NextBuyOpportunity.prepare(code: q.code, book: book, goal: goal, quote: live, research: range, rules: nil, evidence: facts, now: now)
        XCTAssertFalse(unverified.canSavePlan, "a plausible lot size must not be guessed")
        let publicFeed = NextCachedQuote(quote: q, stamp: NextDataStamp(source: "Tencent qt.gtimg.cn", observedAt: now, quality: .live, detail: ""))
        XCTAssertFalse(publicFeed.usableForPricePlan(at: now), "public quotes remain display-only until a vetted price-plan source is configured")
    }
    func testPriceResearchCannotReferenceInventedEvidence() throws {
        let range = NextPriceResearch(lower: 1.2, upper: 1.4, evidenceIDs: ["made-up"], observedAt: now)
        XCTAssertThrowsError(try range.validate(evidence: []))
    }
    func testAuditedBookCanUndoOnlyTheLatestMatchingChange() throws {
        var ledger = NextAuditedBook(current: NextBook())
        var changed = ledger.current; changed.cash = 100
        try ledger.apply(changed, action: "修改现金", reason: "用户确认", at: now)
        let id = try XCTUnwrap(ledger.events.last?.id)
        try ledger.undo(id, at: now.addingTimeInterval(1))
        XCTAssertEqual(ledger.current.cash, 0)
        XCTAssertNotNil(ledger.events.last?.undoneAt)
        XCTAssertThrowsError(try ledger.undo(id, at: now.addingTimeInterval(2)))
    }
    func testNotificationDedupeAndQuietHoursAcrossMidnight() {
        var center = NextNotificationCenter(); center.dedupeMinutes = 30
        center.quietHours = NextQuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23, minute: 15))!
        XCTAssertTrue(center.quietHours.isQuiet(date, calendar: calendar))
        let stamp = NextDataStamp(source: "feed", observedAt: date, quality: .live, detail: "")
        let alert = NextAlert(fingerprint: "159941:price:1.5", level: "P1", title: "观察价", detail: "触发", createdAt: date, stamp: stamp)
        XCTAssertTrue(center.append(alert, now: date))
        var duplicate = alert; duplicate.id = UUID()
        XCTAssertFalse(center.append(duplicate, now: date.addingTimeInterval(60)))
        XCTAssertEqual(center.alerts.count, 1)
    }
    func testPriceAlertRuleRequiresAValidInstrumentAndPositivePrice() throws {
        let valid = NextPriceAlertRule(code: "159941", name: "纳指ETF", price: 1.2, direction: .atOrBelow)
        XCTAssertNoThrow(try valid.validate())
        XCTAssertThrowsError(try NextPriceAlertRule(code: "bad", name: "", price: 0, direction: .atOrAbove).validate())
    }
    func testNavigationRestoresSecurityFiltersChartAndCrosshair() throws {
        var nav = NextNavigationState(); nav.listFilters["market"] = "ETF"; nav.scrollAnchors["watchlist"] = "159941"
        nav.openInstrument("159941"); nav.openIntent("buy-opportunity", code: "159941")
        nav.tabRoutes[NextTab.market.rawValue] = [.instrument("159941"), .chart("159941")]
        nav.chartStates["159941"] = NextChartState(interval: "1d", visibleLayers: ["price", "iopv", "cost"], lowerBound: now, upperBound: now.addingTimeInterval(60), crosshairTime: now.addingTimeInterval(20), scale: 2)
        let roundTrip = try JSONDecoder().decode(NextNavigationState.self, from: JSONEncoder().encode(nav))
        XCTAssertEqual(roundTrip, nav)
        XCTAssertEqual(roundTrip.selectedSecurity, "159941")
        XCTAssertEqual(roundTrip.chartStates["159941"]?.crosshairTime, now.addingTimeInterval(20))
    }
    func testAThroughHTwinStrategiesKeepAutonomousAIAndAddCustomStrategy() {
        XCTAssertEqual(NextTwinStrategy.allCases.map(\.rawValue), ["A", "B", "C", "D", "E", "F", "G", "H"])
        XCTAssertEqual(Set(NextTwinStrategy.allCases.map(\.title)).count, 8)
        XCTAssertEqual(NextTwinStrategy.G.title, "AI 多因子自主模拟交易")
        XCTAssertEqual(NextTwinStrategy.H.title, "用户自定义策略")
    }
    func testPatientLimitPlanIsAValidatedReminderAndRequiresFreshQuote() throws {
        let plan = NextPatientLimitPlan(id: UUID(), code: "159941", name: "纳指ETF", limitPrice: Decimal(string: "1.35")!, units: 100,
            createdAt: now, expiresAt: now.addingTimeInterval(86400))
        try plan.validate()
        XCTAssertTrue(plan.shouldTrigger(with: quote(time: now, price: Decimal(string: "1.35")!), at: now))
        XCTAssertFalse(plan.shouldTrigger(with: quote(time: now, price: Decimal(string: "1.36")!), at: now))
        XCTAssertFalse(plan.shouldTrigger(with: quote(time: now.addingTimeInterval(-121), price: 1.2), at: now))
        XCTAssertFalse(plan.shouldTrigger(with: NextQuote(code: "563020", name: "其他ETF", price: 1, previousClose: 1, time: now, source: "test"), at: now))
        var paused = plan; paused.state = "已暂停"
        try paused.validate()
        XCTAssertFalse(paused.shouldTrigger(with: quote(time: now, price: 1.2), at: now))
        var invalid = plan
        invalid.state = "已成交"
        XCTAssertThrowsError(try invalid.validate())
    }
    func testBacktestResultIsValidatedCachedAndKeptOutOfRealBook() throws {
        let result = NextTwinBacktest(runId: "test-run", strategy: "B", engine: "point-in-time daily OHLC replay", realOrder: false,
            queueAccuracy: "daily bars cannot prove order-book queue fills", aiSignalAccuracy: "proxy", source: "NAS daily K",
            startDate: "2026-10-19", endDate: "2026-10-20", sessions: 2, codes: ["159941"], initialWeights: ["159941": "1"], parameters: [:], feePerFill: "0.10",
            initialCash: "10000", externalContributions: "0", endingEquity: "10000", totalReturn: "0", annualizedReturn: "0",
            annualizedVolatility: "0", sharpe: "0", calmar: "0", maxDrawdown: "0", feesPaid: "0", tradeCount: 0,
            openPositions: ["159941": 0], pendingOrders: [],
            curve: [.init(date: "2026-10-19", equity: "10000", cash: "10000", nav: "1", externalFlow: "0"),
                    .init(date: "2026-10-20", equity: "10000", cash: "10000", nav: "1", externalFlow: "0")], fills: [])
        try result.validate()
        XCTAssertNotNil(result.equityChartDataset())
        var archive = NextAppArchive(); archive.twinBacktests["B"] = result
        let copied = try NextArchiveEnvelope(archive: archive).archive()
        XCTAssertEqual(copied.twinBacktests["B"], result)
        XCTAssertTrue(copied.book.positions.isEmpty)
    }
    // IOPV 图层是可选的：关掉时纵轴只按成交价，不被 IOPV 撑开；
    // 打开时才把 IOPV 纳入同一根价格轴（UnifiedChartView 也按 visibleLayers 处理）。
    func testChartPriceDomainFollowsIOPVLayerVisibility() throws {
        let first = NextChartSample(timestamp: now, open: 1.0, high: 1.1, low: 0.9, close: 1.05, iopv: 4, volume: 100)
        let later = NextChartSample(timestamp: now.addingTimeInterval(3600), open: 1.1, high: 1.2, low: 1.0, close: 1.15, iopv: 4.1, volume: 200)
        let chart = NextChartDataset(code: "159941", interval: .intraday, samples: [later, first], costPerUnit: 1.02, costObservedAt: now, priceSource: "feed", iopvSource: "feed", observedAt: now)
        try chart.validate()
        XCTAssertEqual(chart.orderedSamples.map(\.timestamp), [now, now.addingTimeInterval(3600)])
        // 关闭 IOPV 图层：价格轴只由成交价决定，上界不越过 2
        XCTAssertLessThan(chart.priceDomain(includingIOPV: false)!.upperBound, 2)
        // 打开 IOPV 图层：价格轴必须覆盖 IOPV
        XCTAssertGreaterThanOrEqual(chart.priceDomain(includingIOPV: true)!.upperBound, Decimal(string: "4.1")!)
        // 属性入口保持默认（含 IOPV），与既有调用兼容
        XCTAssertEqual(chart.priceDomain, chart.priceDomain(includingIOPV: true))
        XCTAssertNotNil(chart.iopvPremiumDomain)
        XCTAssertEqual(chart.timeDomain!.upperBound, now.addingTimeInterval(3600))
    }
    func testUnknownInstrumentRulesCannotClaimT0() throws {
        let rules = NextInstrumentRules(code: "159941", market: "SZ", assetClass: .unknown, settlement: .unknown, lotSize: nil, feePerTrade: nil, source: "未接入", verifiedAt: nil)
        try rules.validate()
        XCTAssertFalse(rules.isVerified)
        let confirmed = NextInstrumentRules(code: "159941", market: "SZ", assetClass: .etf, settlement: .t0, lotSize: 100, feePerTrade: Decimal(string: "0.10"), source: "official", verifiedAt: now)
        XCTAssertTrue(confirmed.isVerified)
    }
    func testOfficialETFBacktestRuleDoesNotInventSettlement() {
        let sz = NextInstrumentRules.verifiedETFMarketRule(code: "159941", market: "SZSE", at: now)
        let sh = NextInstrumentRules.verifiedETFMarketRule(code: "563020", market: "SSE", at: now)
        XCTAssertEqual(sz?.lotSize, 100)
        XCTAssertEqual(sh?.lotSize, 100)
        XCTAssertTrue(sz?.isHistoricalBacktestEligible == true)
        XCTAssertFalse(sz?.isVerified ?? true)
        XCTAssertEqual(sz?.settlement, .unknown)
        XCTAssertNil(NextInstrumentRules.verifiedETFMarketRule(code: "123456", market: "SZSE", at: now))
    }
    func testForegroundMarketClockUsesChinaSessionsAndWeekdays() {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        XCTAssertTrue(NextMarketClock.isRegularSession(formatter.date(from: "2026-10-20 10:00")!))
        XCTAssertTrue(NextMarketClock.isRegularSession(formatter.date(from: "2026-10-20 14:00")!))
        XCTAssertFalse(NextMarketClock.isRegularSession(formatter.date(from: "2026-10-20 12:00")!))
        XCTAssertFalse(NextMarketClock.isRegularSession(formatter.date(from: "2026-10-18 10:00")!))
    }
    func testTwinFundingIsMatchedAcrossAThroughHAndNeverTouchesRealBook() throws {
        let real = NextBook()
        var twins = NextTwinLedger()
        try twins.fundAll(500, reason: "统一月度模拟注资", at: now)
        XCTAssertEqual(twins.accounts.count, 8)
        XCTAssertTrue(NextTwinStrategy.allCases.allSatisfy { twins.accounts[$0.rawValue]?.simulation.cash == 10_500 })
        XCTAssertEqual(real.cash, 0)
        try twins.setPaused(true, strategy: .G)
        XCTAssertTrue(twins.accounts["G"]?.isPaused == true)
        XCTAssertFalse(twins.accounts["A"]?.isPaused ?? true)
    }
    func testTwinFundingIsAtomicWhenAnAccountIsMissing() {
        var twins = NextTwinLedger(); twins.accounts.removeValue(forKey: "H")
        XCTAssertThrowsError(try twins.fundAll(500, reason: "test", at: now))
        XCTAssertTrue(twins.accounts.values.allSatisfy { $0.simulation.cash == 10000 })
    }
    func testBackupChecksumAndSchemaMustValidateBeforeRestore() throws {
        var archive = NextAppArchive(); archive.book.cash = 250; archive.audits = []
        let envelope = try NextArchiveEnvelope(archive: archive)
        XCTAssertEqual(try envelope.archive().book.cash, 250)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        raw["payload"] = (envelope.payload + Data([0])).base64EncodedString()
        let corrupt = try JSONDecoder().decode(NextArchiveEnvelope.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertThrowsError(try corrupt.archive())
        archive.book.positions = [NextPosition(code: "bad", name: "invalid", units: 1, bookCost: 1)]
        XCTAssertThrowsError(try NextArchiveEnvelope(archive: archive))
    }
    func testDecisionHistoryIsIncludedAndLegacyArchiveDefaultsIt() throws {
        var archive = NextAppArchive()
        let decision = try NextResearch.prepare(book: NextBook(), goal: NextGoal(), quotes: [:], now: now)
        archive.decisionHistory = [decision]
        let envelope = try NextArchiveEnvelope(archive: archive)
        XCTAssertEqual(try envelope.archive().decisionHistory, [decision])
        let legacy = try JSONDecoder().decode(NextAppArchive.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.decisionHistory.isEmpty)
    }
    func testGoalTargetWeightsAreValidatedAndOlderSettingsStillDecode() throws {
        let legacy = try JSONDecoder().decode(NextGoal.self, from: Data("{\"years\":10,\"monthlyBudget\":1000,\"concentrationLimit\":40}".utf8))
        XCTAssertTrue(legacy.targetWeights.isEmpty)
        var goal = NextGoal(targetWeights: ["159941": 60, "563020": 40])
        XCTAssertNoThrow(try goal.validate())
        goal.targetWeights["563020"] = 30
        XCTAssertThrowsError(try goal.validate())
    }
    func testDailyChartCacheKeySurvivesBackupValidation() throws {
        let sample = NextChartSample(timestamp: now, open: 1.0, high: 1.1, low: 0.9, close: 1.05, iopv: nil, volume: 100)
        let daily = NextChartDataset(code: "159941", interval: .day, samples: [sample], costPerUnit: nil, costObservedAt: nil, priceSource: "NAS", iopvSource: nil, observedAt: now)
        var archive = NextAppArchive(); archive.chartData["159941:day"] = daily
        XCTAssertEqual(try NextArchiveEnvelope(archive: archive).archive().chartData["159941:day"], daily)
        archive.chartData = ["bad:day": daily]
        XCTAssertThrowsError(try NextArchiveEnvelope(archive: archive))
    }
    func testLastTradeQuoteCannotSimulateOrderExecution() throws {
        var sim = NextExperiment()
        try sim.place(code: "159941", limit: 1.5, units: 100, rules: etfRules(), at: now, until: now.addingTimeInterval(3600))
        sim.observe(quote(time: now.addingTimeInterval(1), price: 1), now: now.addingTimeInterval(1), marketOpen: true)
        XCTAssertEqual(sim.orders[0].state, "等待")
        XCTAssertTrue(sim.positions.isEmpty)
    }
    func testTencentQuoteParserChecksSymbolFieldsAndSourceTime() {
        XCTAssertEqual(NextTencentQuoteParser.symbol(for: "159941"), "sz159941")
        XCTAssertEqual(NextTencentQuoteParser.symbol(for: "510300"), "sh510300")
        XCTAssertNil(NextTencentQuoteParser.symbol(for: "12345"))
        var fields = Array(repeating: "", count: 90)
        fields[1] = "纳指ETF"; fields[3] = "1.234"; fields[4] = "1.200"
        fields[30] = "20261019143000"
        fields[61] = "ETF"
        fields[78] = "1.230"
        let payload = "v_sz159941=\"\(fields.joined(separator: "~"))\";"
        let received = ISO8601DateFormatter().date(from: "2026-10-19T06:30:30Z")!
        let combined = "v_sh510300=\"\(fields.joined(separator: "~"))\";" + payload
        let quote = NextTencentQuoteParser.parse(Data(combined.utf8), code: "159941", receivedAt: received)
        XCTAssertEqual(quote?.name, "纳指ETF")
        XCTAssertEqual(quote?.price, Decimal(string: "1.234"))
        XCTAssertEqual(quote?.previousClose, Decimal(string: "1.200"))
        XCTAssertEqual(quote?.iopv, Decimal(string: "1.230"))
        XCTAssertEqual(quote?.providerInstrumentType, "ETF")
        XCTAssertNotNil(NextTencentQuoteParser.parse(Data(combined.utf8), code: "510300", receivedAt: received))
        XCTAssertNil(NextTencentQuoteParser.parse(Data(payload.utf8), code: "510300", receivedAt: received))
        fields[61] = "Stock"
        let nonETF = "v_sz159941=\"\(fields.joined(separator: "~"))\";"
        XCTAssertNil(NextTencentQuoteParser.parse(Data(nonETF.utf8), code: "159941", receivedAt: received)?.iopv)
        XCTAssertNil(NextTencentQuoteParser.parse(Data("v_sz159941=\"bad\"".utf8), code: "159941", receivedAt: received))
    }
    func testTencentMinuteParserKeepsActualTimePriceVolumeAndNoInventedIOPV() throws {
        let json: [String: Any] = ["data": ["sz159941": ["data": ["date": "20261019", "data": ["1430 1.234 1000", "1431 1.240 1200"]]]]]
        let body = "min_data_sz159941=\(try JSONSerialization.data(withJSONObject: json).utf8String);"
        let received = ISO8601DateFormatter().date(from: "2026-10-19T06:31:30Z")!
        let dataset = try XCTUnwrap(NextTencentMinuteParser.parse(Data(body.utf8), code: "159941", receivedAt: received))
        XCTAssertEqual(dataset.samples.count, 2)
        XCTAssertEqual(dataset.samples[0].close, Decimal(string: "1.234"))
        XCTAssertEqual(dataset.samples[1].volume, 200)
        XCTAssertNil(dataset.samples[0].iopv)
        XCTAssertNil(dataset.iopvSource)
        try dataset.validate()
    }
    func testFixedIntradayAxisCoversFullSessionAndCompressesLunch() throws {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let open = try XCTUnwrap(formatter.date(from: "2026-10-20 09:30"))
        let morningEnd = try XCTUnwrap(formatter.date(from: "2026-10-20 11:30"))
        let lunch = try XCTUnwrap(formatter.date(from: "2026-10-20 12:15"))
        let afternoon = try XCTUnwrap(formatter.date(from: "2026-10-20 13:00"))
        let close = try XCTUnwrap(formatter.date(from: "2026-10-20 15:00"))
        XCTAssertEqual(NextIntradayAxis.minute(open), 0)
        XCTAssertEqual(NextIntradayAxis.minute(morningEnd), 120)
        XCTAssertEqual(NextIntradayAxis.minute(lunch), 126, accuracy: 0.001)
        XCTAssertEqual(NextIntradayAxis.minute(afternoon), 132)
        XCTAssertEqual(NextIntradayAxis.minute(close), NextIntradayAxis.length)
        XCTAssertEqual(NextIntradayAxis.length, 252)
        XCTAssertEqual(NextIntradayAxis.ticks.first?.1, "09:30")
        XCTAssertEqual(NextIntradayAxis.ticks.last?.1, "15:00")
        XCTAssertTrue(NextIntradayAxis.sameTradingDay(open, close))
        XCTAssertFalse(NextIntradayAxis.sameTradingDay(open, close.addingTimeInterval(86_400)))
    }
    func testIntradayArchiveSelectsOneTradingDayAndDefaultsToNewest() throws {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let first = try XCTUnwrap(formatter.date(from: "2026-10-19 09:30"))
        let second = try XCTUnwrap(formatter.date(from: "2026-10-20 09:30"))
        let samples = [
            NextChartSample(timestamp: first, open: nil, high: nil, low: nil, close: 1, iopv: nil, volume: nil),
            NextChartSample(timestamp: second, open: nil, high: nil, low: nil, close: 2, iopv: nil, volume: nil)
        ]
        XCTAssertEqual(NextIntradayAxis.sessionSamples(from: samples, selectedDate: first).map(\.close), [1])
        XCTAssertEqual(NextIntradayAxis.sessionSamples(from: samples, selectedDate: nil).map(\.close), [2])
    }
    func testSimpleMovingAveragesUseDailyCloseAndStayUnavailableUntilFullWindow() throws {
        let bars = (1...5).map { value in
            NextChartSample(timestamp: now.addingTimeInterval(Double(value) * 86_400), open: nil, high: nil, low: nil,
                            close: Decimal(value), iopv: nil, volume: nil)
        }
        XCTAssertEqual(NextMovingAverage.series(bars, period: 3), [nil, nil, 2, 3, 4])
        XCTAssertTrue(NextMovingAverage.series(bars, period: 250).allSatisfy { $0 == nil })
        let fullHistory = (1...250).map { value in
            NextChartSample(timestamp: now.addingTimeInterval(Double(value) * 86_400), open: nil, high: nil, low: nil,
                            close: Decimal(value), iopv: nil, volume: nil)
        }
        XCTAssertEqual(NextMovingAverage.series(fullHistory, period: 250)[249], Decimal(string: "125.5"))
    }
    func testChartStateDecodesBeforeMovingAverageDefaultsWereAdded() throws {
        let oldState = #"{"interval":"day","visibleLayers":["price","cost"],"lowerBound":null,"upperBound":null,"crosshairTime":null,"scale":1}"#.data(using: .utf8)!
        let state = try JSONDecoder().decode(NextChartState.self, from: oldState)
        XCTAssertEqual(state.interval, "day")
        XCTAssertNil(state.movingAverageDefaultsApplied)
        XCTAssertNil(state.latestIntradaySessionDate)
    }
    func testChartPriceDomainIncludesIOPVWhenItExtendsBeyondPriceBars() throws {
        let sample = NextChartSample(timestamp: now, open: 1.0, high: 1.1, low: 0.9, close: 1.05, iopv: 1.4, volume: 100)
        let chart = NextChartDataset(code: "159941", interval: .intraday, samples: [sample], costPerUnit: nil, costObservedAt: nil, priceSource: "feed", iopvSource: "verified ETF quote", observedAt: now)
        let domain = try XCTUnwrap(chart.priceDomain)
        XCTAssertLessThan(domain.lowerBound, 0.9)
        XCTAssertGreaterThan(domain.upperBound, 1.4)
    }
    func testLiveETFIOPVOnlyEnrichesNearestCurrentMinutePoint() throws {
        let first = NextChartSample(timestamp: now, open: nil, high: nil, low: nil, close: 1.2, iopv: nil, volume: 100)
        let last = NextChartSample(timestamp: now.addingTimeInterval(60), open: nil, high: nil, low: nil, close: 1.21, iopv: nil, volume: 100)
        let raw = NextChartDataset(code: "159941", interval: .intraday, samples: [first, last], costPerUnit: nil, costObservedAt: nil, priceSource: "minute", iopvSource: nil, observedAt: now)
        let etf = NextQuote(code: "159941", name: "纳指ETF", price: 1.21, previousClose: 1.2, time: now.addingTimeInterval(90), source: "quote", iopv: 1.205, providerInstrumentType: "ETF")
        let enriched = raw.attachingVerifiedIOPV(etf)
        XCTAssertNil(enriched.samples[0].iopv)
        XCTAssertEqual(enriched.samples[1].iopv, 1.205)
        XCTAssertNotNil(enriched.iopvSource)
        let far = NextQuote(code: "159941", name: "纳指ETF", price: 1.21, previousClose: 1.2, time: now.addingTimeInterval(500), source: "quote", iopv: 1.205, providerInstrumentType: "ETF")
        XCTAssertEqual(raw.attachingVerifiedIOPV(far), raw)
    }
    // MARK: - 本机规则引擎

    private func dailyBars(_ closes: [Double], start: Date? = nil) -> [NextChartSample] {
        let base = start ?? Date(timeIntervalSince1970: 1_700_000_000)
        return closes.enumerated().map { index, value in
            let price = Decimal(string: String(format: "%.4f", value))!
            return NextChartSample(timestamp: base.addingTimeInterval(Double(index) * 86_400),
                                   open: price, high: price, low: price, close: price,
                                   iopv: nil, volume: 1_000_000)
        }
    }

    func testDividendPointsAreMonotonicAndNeverNegative() {
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: nil), 0)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 0), 0)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 1.9), 0)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 2.5), 2)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 3.5), 5)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 4.5), 8)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 5.5), 11)
        XCTAssertEqual(NextDividendRules.points(forYieldPercent: 9), 14)
    }

    func testDividendYieldPrefersIOPVForOnExchangeETFOnly() {
        // ETF：分母用净值。场内溢价 25% 时，若用场内价会低估股息率。
        let etf = NextDividendRules.yieldPercent(code: "515180", perShare: Decimal(string: "0.06")!, price: 1.25, iopv: 1.0)
        XCTAssertEqual(etf ?? 0, 6, accuracy: 0.0001)
        // 个股：没有 IOPV 概念，分母用现价。
        let stock = NextDividendRules.yieldPercent(code: "600519", perShare: Decimal(string: "0.06")!, price: 1.25, iopv: 1.0)
        XCTAssertEqual(stock ?? 0, 4.8, accuracy: 0.0001)
        // REITs（508/180）不在 ETF 白名单，不能被当作 ETF 套 IOPV。
        XCTAssertFalse(NextDividendRules.isOnExchangeETF("508000"))
        XCTAssertFalse(NextDividendRules.isOnExchangeETF("180101"))
        XCTAssertTrue(NextDividendRules.isOnExchangeETF("159941"))
        XCTAssertTrue(NextDividendRules.isOnExchangeETF("515180"))
    }

    func testWorthBuyNeedsEnoughDailyBars() {
        let quotePrice = Decimal(string: "1.20")!
        let short = dailyBars(Array(repeating: 1.2, count: 12))
        XCTAssertNil(NextWorthBuyEngine.evaluate(code: "159941", price: quotePrice, previousClose: quotePrice,
                                                 samples: short, dividendPerShare: 0, iopv: nil,
                                                 costPerUnit: nil, weightPercent: nil, positionLimitPercent: nil))
        let enough = dailyBars(Array(repeating: 1.2, count: 40))
        XCTAssertNotNil(NextWorthBuyEngine.evaluate(code: "159941", price: quotePrice, previousClose: quotePrice,
                                                    samples: enough, dividendPerShare: 0, iopv: nil,
                                                    costPerUnit: nil, weightPercent: nil, positionLimitPercent: nil))
        // 40 根平盘样本：均线全部交织、无动量，分数必须落在合法区间且不被抬高。
        let signal = NextSignalEngine.evaluate(enough)
        XCTAssertNotNil(signal)
        XCTAssertTrue((signal?.score ?? -1) >= 0 && (signal?.score ?? 101) <= 100)
        XCTAssertEqual(signal?.trend, "均线交织 · 震荡")
    }

    func testIncomePlayDampensSameDayChangePenalty() {
        let bars = dailyBars(Array(repeating: 1.0, count: 40))
        let price = Decimal(string: "0.97")!
        let previous = Decimal(string: "1.0")!
        let plain = NextWorthBuyEngine.evaluate(code: "159941", price: price, previousClose: previous,
                                                samples: bars, dividendPerShare: 0, iopv: nil,
                                                costPerUnit: nil, weightPercent: nil, positionLimitPercent: nil)
        let income = NextWorthBuyEngine.evaluate(code: "515180", price: price, previousClose: previous,
                                                 samples: bars, dividendPerShare: Decimal(string: "0.04")!,
                                                 iopv: nil, costPerUnit: nil, weightPercent: nil, positionLimitPercent: nil)
        XCTAssertNotNil(plain)
        XCTAssertNotNil(income)
        XCTAssertTrue(income?.isIncomePlay == true)
        // 当天跌 3%：普通标的按 -8 计，红利标的只按 -2.67 计。
        let plainChange = plain?.lines.first(where: { $0.title == "当日涨跌" })?.points ?? 0
        let incomeChange = income?.lines.first(where: { $0.title == "当日涨跌" })?.points ?? 0
        XCTAssertEqual(plainChange, -8)
        XCTAssertTrue(incomeChange > plainChange)
    }

    func testGridCheckRefusesToGradeWithTooFewBars() {
        let bars = dailyBars(Array(repeating: 1.0, count: 30))
        let check = NextGridCheckEngine.evaluate(code: "159941", name: "纳指ETF", samples: bars, isOnExchange: true)
        XCTAssertEqual(check.grade, .avoid)
        XCTAssertEqual(check.barCount, 30)
        XCTAssertTrue(check.warnings.contains { $0.contains("60") })
    }

    func testAccountAdvisorFlagsConcentrationAndMissingQuote() {
        let book = NextBook(cash: 1000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 10_000, bookCost: Decimal(string: "12000")!)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: Decimal(string: "1.2")!, previousClose: Decimal(string: "1.2")!, time: now, source: "test")
        let review = NextAccountAdvisor.review(book: book, quotes: ["159941": quote], concentrationLimitPercent: 40)
        XCTAssertNotNil(review)
        XCTAssertTrue(review?.findings.contains { $0.title.contains("超过单仓上限") } == true)
        // 缺报价的持仓要单独提示，不能静默算进比例。
        let missing = NextBook(cash: 1000, positions: [
            NextPosition(code: "515180", name: "红利ETF", units: 100, bookCost: 100)
        ])
        let missingReview = NextAccountAdvisor.review(book: missing, quotes: [:], concentrationLimitPercent: 40)
        XCTAssertTrue(missingReview?.findings.contains { $0.title.contains("缺报价") } == true)
    }

    func testMACDSeriesWarmsUpBeforeReturningValues() {
        let flat = Array(repeating: 1.0, count: 60)
        let series = NextMACD.series(flat)
        XCTAssertEqual(series.count, 60)
        XCTAssertTrue(series.prefix(33).allSatisfy { $0 == nil })
        XCTAssertNotNil(series[33])
        XCTAssertEqual(series[59]?.histogram ?? 1, 0, accuracy: 0.000001)
    }

    func testGlobalIndexParserReadsFiveUserSelectedIndices() {
        // 这一段是 2026-10-20 12:59 从新浪实际抓到的响应（原样）。
        let body = """
        var hq_str_s_sh000001="上证指数,3727.7542,-3.1658,-0.08,2485176,44185013";
        var hq_str_gb_$ndx="纳斯达克100,29529.3445,1.17,2026-10-20 05:30:00,341.7958,29539.3116,29788.7588,29461.3209";
        var hq_str_b_NKY="日经225指数,64056.2800,-860.42,-1.33,2:12 AM,14:12:00,2026-10-20,12:59:20,64755.4900";
        var hq_str_b_KOSPI="韩国KOSPI指数,5522.8000,-245.21,-4.25,2:27 AM,14:27:00,2026-10-20,12:59:20,5733.5700";
        var hq_str_rt_hkHSTECH="HSTECH,恒生科技指数,4055.520,4108.240,4083.660,4033.240,4058.390,-49.850,-1.210,0.000,0.000,22406330,546961768,0.000,0.000,6198.680,4042.050,2026/10/20,12:59:56";
        """
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = formatter.date(from: "2026-10-20 13:00:00")!
        let quotes = GlobalIndexFeed.parse(body, now: now)
        // 顺序与本地目录一致：上证、纳指100、日经、韩国、恒生科技。
        XCTAssertEqual(quotes.map(\.symbol), GlobalIndexFeed.catalog.map { $0.symbol })
        XCTAssertEqual(quotes.count, 5)
        XCTAssertEqual(quotes[0].price, 3727.7542, accuracy: 0.0001)
        XCTAssertEqual(quotes[0].changePercent, -0.08, accuracy: 0.0001)
        XCTAssertEqual(quotes[1].price, 29529.3445, accuracy: 0.0001)
        XCTAssertEqual(quotes[1].changePercent, 1.17, accuracy: 0.0001)
        XCTAssertEqual(quotes[2].price, 64056.28, accuracy: 0.0001)
        XCTAssertEqual(quotes[3].price, 5522.80, accuracy: 0.0001)
        // 港股用第 6 位现价、第 8 位涨跌幅，不是第 1/2 位。
        XCTAssertEqual(quotes[4].price, 4058.39, accuracy: 0.0001)
        XCTAssertEqual(quotes[4].changePercent, -1.21, accuracy: 0.0001)
        XCTAssertEqual(quotes[4].previousClose ?? 0, 4108.24, accuracy: 0.0001)
        // 最新时点与本地时间相差 1 小时以内，不能判陈旧。
        XCTAssertFalse(quotes[1].isStale)
        XCTAssertNotNil(quotes[2].observedAt)
    }

    func testCostBasisKeepsAverageCostAndComputesDilutedCost() {
        // 买 1000 份 @1.00（费 0.10），再卖 500 份 @1.20（费 0.10），剩 500 份。
        let book = NextBook(cash: 0, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 500, bookCost: Decimal(string: "500.05")!)
        ], fills: [
            NextFill(date: now, code: "159941", side: "buy", units: 1000, price: 1, fee: Decimal(string: "0.10")!, realized: 0),
            NextFill(date: now, code: "159941", side: "sell", units: 500, price: Decimal(string: "1.20")!, fee: Decimal(string: "0.10")!, realized: 0)
        ])
        let basis = book.costBasis(for: "159941")
        XCTAssertNotNil(basis)
        // 买入均价：只由买入决定，(1000 + 0.10) / 1000。
        XCTAssertEqual(basis?.averageCost ?? 0, Decimal(string: "1.0001")!)
        // 摊薄成本：(1000.10 − 599.90) / 500 = 0.8004，卖出盈利把成本压低。
        XCTAssertEqual(basis?.dilutedCost ?? 0, Decimal(string: "0.8004")!)
        XCTAssertTrue(basis?.hasFullHistory == true)
    }

    func testCostBasisRefusesDilutedCostWithoutBuyFills() {
        // 补录的已有持仓没有买入流水，摊薄口径不成立，不能凭空造一个成本。
        let book = NextBook(cash: 0, positions: [
            NextPosition(code: "515180", name: "红利ETF", units: 100, bookCost: 120)
        ])
        let basis = book.costBasis(for: "515180")
        XCTAssertNotNil(basis)
        XCTAssertNil(basis?.dilutedCost)
        XCTAssertFalse(basis?.hasFullHistory == true)
        XCTAssertEqual(basis?.averageCost ?? 0, Decimal(string: "1.2")!)
    }

    func testDailyChangeUsesBuyPriceForTodaysPurchases() {
        // 昨仓 1000 份（昨收 1.00），今天再买 500 份 @1.02，现价 1.05。
        let book = NextBook(cash: 1000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 1500, bookCost: Decimal(string: "1510.1")!)
        ], fills: [
            NextFill(date: now, code: "159941", side: "buy", units: 500, price: Decimal(string: "1.02")!, fee: Decimal(string: "0.10")!, realized: 0)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: Decimal(string: "1.05")!,
                              previousClose: 1, time: now.addingTimeInterval(-5), source: "test")
        let stamp = NextDataStamp(source: "test", observedAt: now, quality: .live, detail: "")
        let valuation = book.valuation(using: ["159941": NextCachedQuote(quote: quote, stamp: stamp)], at: now)
        // 昨仓：(1.05 − 1.00) × 1000 = 50；今买：(1.05 − 1.02) × 500 − 0.10 = 14.9
        XCTAssertEqual(valuation.dailyChange, Decimal(string: "64.9")!)
    }

    func testPortfolioSummaryComparesAverageAndDilutedCost() {
        let yesterday = now.addingTimeInterval(-86_400)
        let book = NextBook(cash: 0, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 500, bookCost: Decimal(string: "500.05")!)
        ], fills: [
            NextFill(date: yesterday, code: "159941", side: "buy", units: 1000, price: 1,
                     fee: Decimal(string: "0.10")!, realized: 0),
            NextFill(date: yesterday, code: "159941", side: "sell", units: 500,
                     price: Decimal(string: "1.20")!, fee: Decimal(string: "0.10")!, realized: Decimal(string: "99.90")!)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: Decimal(string: "1.30")!,
                              previousClose: Decimal(string: "1.28")!, time: now.addingTimeInterval(-5), source: "test")
        let stamp = NextDataStamp(source: "test", observedAt: now, quality: .live, detail: "")
        let quotes = ["159941": NextCachedQuote(quote: quote, stamp: stamp)]

        let average = NextPortfolioCalculator.summary(book: book, quotes: quotes, at: now, mode: .average)
        let diluted = NextPortfolioCalculator.summary(book: book, quotes: quotes, at: now, mode: .diluted)
        // 市值 500 × 1.30 = 650；均价成本 500.05 → 149.95；摊薄成本 400.20 → 249.80
        XCTAssertEqual(average.floatingProfit, Decimal(string: "149.95")!)
        XCTAssertEqual(diluted.floatingProfit, Decimal(string: "249.80")!)
        // 昨日成交不参与今日调整：(1.30 − 1.28) × 500 = 10
        XCTAssertEqual(average.dailyChange, Decimal(string: "10")!)
        XCTAssertEqual(average.positions.first?.weightPercent ?? 0, 100, accuracy: 0.0001)
        XCTAssertEqual(average.realizedTotal, Decimal(string: "99.90")!)
    }

    func testPortfolioSummaryWithholdsDailyChangeWhenQuoteMissing() {
        let book = NextBook(cash: 1000, positions: [
            NextPosition(code: "159941", name: "纳指ETF", units: 500, bookCost: 500),
            NextPosition(code: "515180", name: "红利ETF", units: 100, bookCost: 120)
        ])
        let quote = NextQuote(code: "159941", name: "纳指ETF", price: 1, previousClose: 1,
                              time: now.addingTimeInterval(-5), source: "test")
        let stamp = NextDataStamp(source: "test", observedAt: now, quality: .live, detail: "")
        let summary = NextPortfolioCalculator.summary(book: book,
            quotes: ["159941": NextCachedQuote(quote: quote, stamp: stamp)], at: now, mode: .average)
        XCTAssertFalse(summary.isComplete)
        XCTAssertNil(summary.dailyChange)
        XCTAssertEqual(summary.positions.count, 1)
    }

    func testPerformanceSummaryRemovesExternalFlows() {
        let points = [
            NextAssetPoint(date: now, total: 1000, externalFlow: 0),
            NextAssetPoint(date: now.addingTimeInterval(86_400), total: 1600, externalFlow: 500),
            NextAssetPoint(date: now.addingTimeInterval(172_800), total: 1100, externalFlow: 0)
        ]
        let summary = NextPerformanceCalculator.summary(points: points)
        // 第 2 天：(1600 − 500) / 1000 − 1 = +10%；第 3 天：1100 / 1600 − 1 = −31.25%
        // 连乘 1.10 × 0.6875 = 0.75625 → −24.375%
        XCTAssertEqual(summary?.cumulativePercent ?? 0, -24.375, accuracy: 0.0001)
        XCTAssertNil(summary?.annualizedPercent)
        XCTAssertEqual(summary?.dayCount, 2)
        XCTAssertEqual(summary?.maxDrawdownPercent ?? 0, 31.25, accuracy: 0.0001)
    }

    func testCatalogSearchMatchesNameAndInitialsButNotEmptyQuery() {
        XCTAssertTrue(InstrumentCatalog.search("").isEmpty)
        XCTAssertTrue(InstrumentCatalog.search("红利").contains { $0.code == "515180" })
        XCTAssertTrue(InstrumentCatalog.search("nz").contains { $0.code == "159941" })
        XCTAssertTrue(InstrumentCatalog.search("5103").contains { $0.code == "510300" })
        XCTAssertTrue(InstrumentCatalog.search("不存在的名字").isEmpty)
    }

    func testInstrumentGroupClassifiesKnownPrefixedCodes() {
        XCTAssertEqual(NextInstrumentGroup.classify(code: "515180", name: "红利ETF"), .dividend)
        XCTAssertEqual(NextInstrumentGroup.classify(code: "513100", name: "纳指100ETF"), .overseas)
        XCTAssertEqual(NextInstrumentGroup.classify(code: "510300", name: "沪深300ETF"), .broad)
        XCTAssertEqual(NextInstrumentGroup.classify(code: "511010", name: "国债ETF"), .bond)
        XCTAssertEqual(NextInstrumentGroup.classify(code: "600519", name: "贵州茅台"), .equity)
    }

    func testForwardAdjustmentLowersHistoryAfterDividendOnly() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        let before = formatter.date(from: "2026-01-05")!
        let after = formatter.date(from: "2026-03-05")!
        let samples = [
            NextChartSample(timestamp: before, open: 1.0, high: 1.1, low: 0.9, close: 1.0, iopv: nil, volume: 100),
            NextChartSample(timestamp: after, open: 1.0, high: 1.1, low: 0.9, close: 1.0, iopv: nil, volume: 100)
        ]
        let events = [NextETFDividendEvent(code: "510300", date: "2026-02-01", amountPerShare: Decimal(string: "0.05")!)]
        let adjusted = NextPriceAdjustment.forwardAdjusted(samples, events: events, code: "510300")
        // 除息日之前的那根下调 0.05，之后的保持原值。
        XCTAssertEqual(adjusted[0].close, Decimal(string: "0.95")!)
        XCTAssertEqual(adjusted[1].close, 1.0)
        // 没有派息事件时原样返回。
        XCTAssertEqual(NextPriceAdjustment.forwardAdjusted(samples, events: [], code: "510300"), samples)
    }

    func testBenchmarkReturnUsesSameWindow() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.date(from: "2026-01-01")!
        let samples = (0..<5).map { index -> NextChartSample in
            let price = Decimal(string: String(format: "%.1f", 100 + Double(index) * 10))!
            return NextChartSample(timestamp: start.addingTimeInterval(Double(index) * 86_400),
                                   open: price, high: price, low: price, close: price, iopv: nil, volume: 1)
        }
        // 从第 100 点到第 140 点：+40%
        let value = NextBenchmark.returnPercent(samples: samples, from: start, to: start.addingTimeInterval(4 * 86_400))
        XCTAssertEqual(value ?? 0, 40, accuracy: 0.0001)
        XCTAssertNil(NextBenchmark.returnPercent(samples: [], from: start, to: start))
    }

}

private extension Data {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
