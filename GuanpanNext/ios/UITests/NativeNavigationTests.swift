import XCTest

final class NativeNavigationTests: XCTestCase {
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFivePrimaryScreensAndSettingsRenderOnDevice() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["总览"].waitForExistence(timeout: 10))
        attach(app, "01-overview")
        for title in ["行情", "AI 决策", "量化", "资产"] {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "Missing tab \(title)")
            tab.tap()
            attach(app, "primary-\(title)")
        }
        // 首帧刚出时按钮还没进无障碍树，直接 tap 会 "Failed to tap ... Button"。
        // 所有首次点击都必须先等元素出现。
        let settingsButton = app.buttons["settings.open"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        attach(app, "settings")
    }

    func testInstrumentAndFullscreenChartNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "1"]
        app.launch()
        app.tabBars.buttons["行情"].tap()
        let security = app.buttons["instrument.row.159941"].firstMatch
        XCTAssertTrue(security.waitForExistence(timeout: 5))
        security.tap()
        XCTAssertTrue(app.navigationBars["纳指 ETF"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["行情图表"].exists)
        attach(app, "instrument-detail")
        app.buttons["chart.fullscreen"].tap()
        XCTAssertTrue(app.navigationBars["全屏行情分析"].waitForExistence(timeout: 5))
        attach(app, "chart-fullscreen")
        let plot = app.otherElements["chart.plot"]
        if plot.waitForExistence(timeout: 2) {
            let start = plot.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.48))
            let end = plot.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.48))
            start.press(forDuration: 0.1, thenDragTo: end)
            plot.pinch(withScale: 1.4, velocity: 1)
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        attach(app, "chart-landscape")
        XCUIDevice.shared.orientation = .portrait
        let backStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.45))
        backStart.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45)))
        XCTAssertTrue(app.navigationBars["纳指 ETF"].waitForExistence(timeout: 5))
        app.buttons["instrument.analyze-buy"].tap()
        XCTAssertTrue(app.staticTexts["私人投资顾问"].waitForExistence(timeout: 5))
        attach(app, "instrument-ai-deep-link")
    }

    func testListSwipeOffersContextualAIAction() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "1"]
        app.launch()
        app.tabBars.buttons["行情"].tap()
        let row = app.buttons["instrument.row.159941"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        let analyze = app.buttons["分析"].firstMatch
        XCTAssertTrue(analyze.waitForExistence(timeout: 3))
        analyze.tap()
        XCTAssertTrue(app.staticTexts["私人投资顾问"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "纳指 ETF")).firstMatch.exists)
        attach(app, "market-swipe-ai-context")
    }

    func testGlobalSearchCanOpenAIAnalysisAndTwinStrategy() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "1"]
        app.launch()
        let searchButton = app.buttons["全局搜索证券"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10))
        searchButton.tap()
        XCTAssertTrue(app.navigationBars["全局搜索"].waitForExistence(timeout: 5))
        let field = app.textFields["输入代码或名称"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("159941")
        let analyze = app.buttons["分析 纳指 ETF 买入机会"]
        XCTAssertTrue(analyze.waitForExistence(timeout: 5))
        analyze.tap()
        XCTAssertTrue(app.staticTexts["私人投资顾问"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "159941")).firstMatch.exists)
        attach(app, "global-search-security-to-ai")

        let searchAgain = app.buttons["全局搜索证券"]
        XCTAssertTrue(searchAgain.waitForExistence(timeout: 10))
        searchAgain.tap()
        let strategySearch = app.textFields["输入代码或名称"]
        XCTAssertTrue(strategySearch.waitForExistence(timeout: 3))
        if app.buttons["search.clear"].exists { app.buttons["search.clear"].tap() }
        strategySearch.tap()
        strategySearch.typeText("G")
        let strategyHit = app.buttons["search.hit.strategy-G"]
        XCTAssertTrue(strategyHit.waitForExistence(timeout: 5))
        strategyHit.tap()
        XCTAssertTrue(app.navigationBars["策略详情"].waitForExistence(timeout: 5))
        attach(app, "global-search-twin-strategy")
    }

    func testLightDarkComfortAndAccessibilityTextSizes() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "1"]
        app.launch()
        let settingsEntry = app.buttons["settings.open"]
        XCTAssertTrue(settingsEntry.waitForExistence(timeout: 10))
        settingsEntry.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        let theme = app.segmentedControls["settings.theme"]
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        for title in ["浅色", "深色", "护眼"] {
            theme.buttons[title].tap()
            attach(app, "theme-\(title)")
        }
        app.terminate()
        let largeText = XCUIApplication()
        largeText.launchArguments += ["-ui-testing", "1", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"]
        largeText.launch()
        XCTAssertTrue(largeText.tabBars.buttons["总览"].waitForExistence(timeout: 10))
        attach(largeText, "overview-accessibility-text")
        largeText.tabBars.buttons["资产"].tap()
        XCTAssertTrue(largeText.staticTexts["真实资产"].waitForExistence(timeout: 5))
        attach(largeText, "assets-accessibility-text")
    }
}
