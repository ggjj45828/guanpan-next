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
    func testChartUsesActualTimeAndPriceDomainDoesNotExpandForIOPV() throws {
        let first = NextChartSample(timestamp: now, open: 1.0, high: 1.1, low: 0.9, close: 1.05, iopv: 4, volume: 100)
        let later = NextChartSample(timestamp: now.addingTimeInterval(3600), open: 1.1, high: 1.2, low: 1.0, close: 1.15, iopv: 4.1, volume: 200)
        let chart = NextChartDataset(code: "159941", interval: .intraday, samples: [later, first], costPerUnit: 1.02, costObservedAt: now, priceSource: "feed", iopvSource: "feed", observedAt: now)
        try chart.validate()
        XCTAssertEqual(chart.orderedSamples.map(\.timestamp), [now, now.addingTimeInterval(3600)])
        XCTAssertLessThan(chart.priceDomain!.upperBound, 2)
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
}

private extension Data {
    var utf8String: String { String(decoding: self, as: UTF8.self) }
}
