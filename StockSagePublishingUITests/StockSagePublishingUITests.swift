import XCTest
import CryptoKit
import UIKit
import ImageIO

final class StockSagePublishingUITests: XCTestCase {
    private let bundleID = "SA.StockSage.PublishingUIQA"
    private var caseID = ""
    private var runID = ""
    private var actions: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        executionTimeAllowance = 150
    }

    @MainActor
    func testBrowseLarge() throws { try browse("browse-large", size: "large") }
    @MainActor
    func testBrowseAccessibility3() throws { try browse("browse-accessibility3", size: "accessibility3") }
    @MainActor
    func testBrowseAccessibility5() throws { try browse("browse-accessibility5", size: "accessibility5") }
    @MainActor
    func testOnboardingLarge() throws { try onboarding("onboarding-large", size: "large") }
    @MainActor
    func testOnboardingAccessibility3() throws { try onboarding("onboarding-accessibility3", size: "accessibility3") }

    @MainActor
    func testPhoneFourTabsAndReadOnlySavedResearch() throws {
        let app = try start("navigation-large")
        defer { app.terminate() }
        let tabs = app.tabBars.firstMatch
        try require(tabs.waitForExistence(timeout: 10) && app.tabBars.count == 1, "One real native tab bar required")
        try require(tabs.buttons.count == 4, "The phone must expose exactly four native tabs")
        for (title, heading) in [("Watchlist", "Watchlist"), ("Portfolio", "Holdings & journal"), ("Chat", "Chat"), ("Library", "Library")] {
            let tab = try unique(tabs.buttons, title)
            try require(fullyVisible(tab, in: app), "Every main tab must remain visible and tappable")
            tab.tap()
            try require(tab.isSelected, "Native selection must follow the tapped tab")
            try require(app.navigationBars[heading].waitForExistence(timeout: 8), "The actual selected page must open: " + heading)
            actions.append("open-" + title.lowercased())
            try capture("tab-" + title.lowercased(), app: app)
        }
        try require(!app.buttons["Run same-day research"].exists && !app.buttons["Research both horizons"].exists,
                    "Phone navigation must not offer unavailable Gemma research")
        let reports = try unique(app.buttons, "library.open.briefing")
        reports.tap()
        try require(app.navigationBars["Saved research"].waitForExistence(timeout: 8), "The saved report page must open")
        let saved = try unique(app.buttons, "research.saved")
        saved.tap()
        let readOnly = try unique(app.staticTexts, "research.history.readOnly")
        try require(readOnly.label.contains("Mac"), "Saved reports must explain their read-only provenance")
        for identifier in ["research.history.checkAllOpinions", "research.history.check", "research.history.evaluation"] {
            try require(!app.buttons[identifier].exists, "Phone saved reports must not start outcome checks or model evaluation")
        }
        actions.append("open-read-only-saved-reports")
        try capture("saved-reports", app: app)
        let done = try unique(app.buttons, "Done")
        done.tap()
        try require(saved.waitForExistence(timeout: 8), "Closing the reports must return to their originating page")
        actions.append("dismiss-saved-reports")
        try finish("large", app: app)
    }

    @MainActor
    func testPhoneLegacyResearchSelectionRestoresWatchlist() throws {
        try restoredPhone("navigation-restore-legacy", selected: "Watchlist", heading: "Watchlist")
    }

    @MainActor
    func testPhoneSavedChatSelectionRestoresChat() throws {
        try restoredPhone("navigation-restore-chat", selected: "Chat", heading: "Chat")
    }

    @MainActor
    func testPersonalPriceHoldingAndBackupLarge() throws {
        try personalRecords("personal-records-large", size: "large")
    }

    @MainActor
    func testPersonalPriceHoldingAndBackupAccessibility3() throws {
        try personalRecords("personal-records-accessibility3", size: "accessibility3")
    }

    @MainActor
    private func personalRecords(_ name: String, size: String) throws {
        let app = try start(name)
        defer { app.terminate() }
        try enterPersonal("CSPX.L", identifier: "personalPrice.addTicker", app: app)
        let addTicker = try unique(app.buttons, "personalPrice.addTicker.confirm")
        try revealPersonal(addTicker, in: app); addTicker.tap()
        let record = try unique(app.buttons, "personalPrice.record.CSPX.L")
        try revealPersonal(record, in: app); record.tap()
        try enterPersonal("600", identifier: "personalPrice.entry.price", app: app)
        try enterPersonal("USD", identifier: "denomination.currency", app: app)
        let save = try unique(app.buttons, "personalPrice.entry.save")
        try require(save.isEnabled && fullyVisible(save, in: app), "The actual price form must save a valid explicit denomination")
        save.tap()
        let observation = try unique(app.staticTexts, "personalPrice.value.CSPX.L")
        try revealPersonal(observation, in: app)
        try require(observation.label == "600.00 USD", "London suffix must not turn a declared USD price into pence")
        actions.append("record-CSPX.L-600-USD-major-offline")
        try capture("recorded-price", app: app)
        let portfolio = try unique(app.tabBars.buttons, "Portfolio")
        portfolio.tap()
        try enterPersonal("CSPX.L", identifier: "portfolio.field.Symbol", app: app)
        try enterPersonal("2", identifier: "portfolio.field.Shares", app: app)
        try enterPersonal("500", identifier: "portfolio.field.Cost per share", app: app)
        try enterPersonal("USD", identifier: "denomination.currency", app: app)
        let addHolding = try unique(app.buttons, "portfolio.addHolding")
        try revealPersonal(addHolding, in: app)
        try require(addHolding.isEnabled, "The actual holding form must accept explicit cost units")
        addHolding.tap()
        let value = try unique(app.staticTexts, "portfolio.value.CSPX.L")
        try revealPersonal(value, in: app)
        try require(value.label == "Value: 1200.00 USD", "Two declared dollar shares at600 must equal1200USD")
        let profit = try unique(app.staticTexts, "portfolio.profit.CSPX.L")
        try revealPersonal(profit, in: app)
        try require(profit.label == "P&L: +200.00", "Declared cost500 and mark600 for two shares must equal200USD profit")
        actions.append("record-holding-2-at-500-USD-check-1200-value-200-profit")
        try capture("recorded-holding", app: app)
        try unique(app.tabBars.buttons, "Library").tap()
        let backup = try unique(app.buttons, "library.open.backup")
        try revealPersonal(backup, in: app); backup.tap()
        let prepare = try unique(app.buttons, "personalBackup.prepare")
        try revealPersonal(prepare, in: app); prepare.tap()
        let share = try unique(app.buttons, "personalBackup.share")
        try revealPersonal(share, in: app)
        try require(share.isEnabled && fullyVisible(share, in: app), "A real prepared JSON must be available through the native ShareLink")
        try require(!app.staticTexts["personalBackup.feedback"].exists, "Backup preparation must not report an error")
        actions.append("prepare-five-collection-native-JSON-share")
        try capture("prepared-backup", app: app)
        try finish(size, app: app)
    }

    @MainActor
    private func enterPersonal(_ text: String, identifier: String, app: XCUIApplication) throws {
        let field = try unique(app.textFields, identifier)
        try revealPersonal(field, in: app)
        try require(fieldIsEmptyValue(field), "The new isolated personal fixture must start with empty fields")
        field.tap(); field.typeText(text)
        let done = try unique(app.buttons, "personalInput.done")
        try require(fullyVisible(done, in: app), "Numeric and text keyboards need a reachable production Done action")
        done.tap()
        try require(app.keyboards.firstMatch.waitForNonExistence(timeout: 3), "Done must dismiss the actual keyboard")
        try require(field.value as? String == text, "Typing must preserve the complete entered value")
    }

    @MainActor
    private func revealPersonal(_ element: XCUIElement, in app: XCUIApplication) throws {
        for attempt in 0..<48 {
            if fullyVisible(element, in: app) { return }
            let candidates = (app.scrollViews.allElementsBoundByIndex + app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex).filter {
                $0.exists && $0.isHittable && $0.frame.width >= 300 && $0.frame.height >= 200
                    && app.frame.insetBy(dx: -0.5, dy: -0.5).contains($0.frame)
            }
            try require(candidates.count == 1, "Exactly one visible native personal-record scroll container is required")
            let viewport = candidates[0].frame.insetBy(dx: 6, dy: 8)
            let upward = !element.exists || element.frame.midY >= viewport.midY
            let start = CGPoint(x: viewport.minX + 4, y: upward ? viewport.maxY - 12 : viewport.minY + 12)
            let end = CGPoint(x: start.x, y: start.y + (upward ? -1 : 1) * viewport.height * 0.35)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            print("STOCK_PERSONAL_REVEAL case=\(caseID) attempt=\(attempt + 1) upward=\(upward)")
            origin.withOffset(CGVector(dx: start.x, dy: start.y)).press(forDuration: 0.05,
                thenDragTo: origin.withOffset(CGVector(dx: end.x, dy: end.y)), withVelocity: .slow, thenHoldForDuration: 0.05)
        }
        try require(fullyVisible(element, in: app), "The complete real personal-record control must be visible")
    }

    @MainActor
    private func restoredPhone(_ name: String, selected: String, heading: String) throws {
        let app = try start(name)
        defer { app.terminate() }
        let tabs = app.tabBars.firstMatch
        try require(tabs.waitForExistence(timeout: 10) && tabs.buttons.count == 4, "Restoration must retain all four native tabs")
        let tab = try unique(tabs.buttons, selected)
        try require(tab.isSelected && fullyVisible(tab, in: app), "The restored route must select the supported native tab")
        try require(app.navigationBars[heading].waitForExistence(timeout: 8), "The restored content must match the native tab")
        try require(!app.buttons["Run same-day research"].exists, "Restoration must not revive a server-dependent phone page")
        actions.append("restore-supported-" + selected.lowercased())
        try capture("restored", app: app)
        try finish("large", app: app)
    }

    private enum CheckFailure: Error { case assertion(String) }
    @MainActor
    private func require(_ condition: @autoclosure () -> Bool, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let passed = condition()
        XCTAssertTrue(passed, message, file: file, line: line)
        if !passed { throw CheckFailure.assertion(message) }
    }

    @MainActor
    private func start(_ name: String) throws -> XCUIApplication {
        caseID = name; actions = []
        XCUIDevice.shared.orientation = .portrait
        let value = try XCTUnwrap(ProcessInfo.processInfo.environment["PUBLISHING_UI_RUN_ID"])
        try require(value.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil, "Owned run ID required")
        runID = value
        let app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-set_offlineOnly", "YES", "-set_webAccess", "NO",
                               "--publishing-case", name, "--publishing-run-id", runID]
        if name.hasPrefix("navigation-") || name.hasPrefix("personal-records-") { app.launchArguments.append("--qa") }
        app.launchEnvironment = [:]
        var ready = false
        defer { if !ready { app.terminate() } }
        app.launch()
        try require(app.wait(for: .runningForeground, timeout: 15), "Owned QA app must enter foreground")
        try require(abs(app.frame.width - 375) < 0.01 && abs(app.frame.height - 667) < 0.01,
                    "The actual native phone app must have375x667 points")
        try require(app.windows.firstMatch.waitForExistence(timeout: 5), "Native app window required")
        try require(app.windows.firstMatch.frame == app.frame, "Window must fill the actual native viewport")
        actions.append("native375x667-foreground")
        ready = true
        return app
    }

    @MainActor
    private func unique(_ query: XCUIElementQuery, _ identifier: String) throws -> XCUIElement {
        let matching = query.matching(identifier: identifier)
        try require(matching.firstMatch.waitForExistence(timeout: 8), "Missing real UI element " + identifier)
        try require(matching.count == 1, "UI identity must be unique: " + identifier)
        return matching.element(boundBy: 0)
    }

    @MainActor
    private func fullyVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        element.exists && element.isHittable && !element.frame.isEmpty
        && app.frame.insetBy(dx: -0.5, dy: -0.5).contains(element.frame)
    }

    @MainActor
    private func activeScrollView(in app: XCUIApplication) throws -> XCUIElement {
        let candidates = app.scrollViews.allElementsBoundByIndex.filter {
            $0.exists && $0.isHittable && $0.frame.width >= 300 && $0.frame.height >= 200
            && app.frame.insetBy(dx: -0.5, dy: -0.5).contains($0.frame)
        }
        try require(candidates.count == 1, "Exactly one visible production scroll view is required; no first-match fallback")
        return candidates[0]
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool = true) throws {
        let scroll = try activeScrollView(in: app)
        // Full-screen swipes can jump from below to above a tall row without ever
        // exposing it. Observe the target's frame and correct in either direction.
        // A query may temporarily be absent because the catalog uses lazy content.
        for attempt in 0..<64 {
            let viewport = scroll.frame.insetBy(dx: 0, dy: 2)
            if fullyVisible(element, in: app), viewport.contains(element.frame) { return }
            var forward = up
            var distance = viewport.height * 0.45
            if element.exists {
                let target = element.frame
                try require(target.height <= viewport.height,
                            "A required UI element must fit within the actual scroll viewport")
                if target.minY < viewport.minY {
                    forward = false
                    distance = min(distance, viewport.minY - target.minY + 6)
                } else if target.maxY > viewport.maxY {
                    forward = true
                    distance = min(distance, target.maxY - viewport.maxY + 6)
                }
            }
            distance = max(12, min(distance, viewport.height * 0.45))
            // Keep the drag away from the right-hand row Add buttons.
            let x = viewport.minX + 12
            let fromY = forward ? viewport.maxY - 12 : viewport.minY + 12
            let toY = fromY + (forward ? -distance : distance)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: x - app.frame.minX, dy: fromY - app.frame.minY))
            let to = origin.withOffset(CGVector(dx: x - app.frame.minX, dy: toY - app.frame.minY))
            print("STOCK_REVEAL case=\(caseID) attempt=\(attempt + 1) targetExists=\(element.exists) direction=\(forward ? "up" : "down") distance=\(distance)")
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.05)
        }
        // Avoid asking for a missing element's identifier, which masks this
        // behavior failure with an unrelated snapshot exception.
        try require(element.exists && fullyVisible(element, in: app)
                    && scroll.frame.insetBy(dx: 0, dy: 2).contains(element.frame),
                    "Real scrolling did not fully reveal the requested production element")
    }

    @MainActor
    private func fieldIsEmptyValue(_ field: XCUIElement) -> Bool {
        guard let value = field.value as? String else { return false }
        return value.isEmpty || value == field.placeholderValue
    }

    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) throws {
        for attempt in 0..<3 {
            let count = app.keyboards.count
            if count == 0 { return }
            try require(count == 1, "Interactive dismissal requires exactly one real keyboard")
            let keyboard = app.keyboards.element(boundBy: 0)
            let scroll = try activeScrollView(in: app)
            let appFrame = app.frame
            let scrollFrame = scroll.frame
            let keyboardFrame = keyboard.frame
            for frame in [appFrame, scrollFrame, keyboardFrame] {
                try require(!frame.isEmpty && !frame.isNull
                            && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy { $0.isFinite },
                            "Keyboard drag requires finite, nonempty observed frames")
            }
            try require(appFrame.contains(scrollFrame) && appFrame.contains(keyboardFrame),
                        "Keyboard drag must remain in the actual app viewport")
            let left = max(scrollFrame.minX, keyboardFrame.minX) + 16
            let right = min(scrollFrame.maxX, keyboardFrame.maxX) - 16
            let startY = min(scrollFrame.maxY - 16, keyboardFrame.minY - 24)
            let endY = min(appFrame.maxY - 4, keyboardFrame.maxY - 4)
            let controls = app.descendants(matching: .any).allElementsBoundByIndex.filter {
                [.textField, .secureTextField, .textView, .button, .link, .slider, .switch, .stepper].contains($0.elementType)
                && $0.exists && $0.isHittable && !$0.frame.isEmpty
            }
            let candidates = [
                CGPoint(x: left, y: startY),
                CGPoint(x: right, y: startY),
                CGPoint(x: left, y: scrollFrame.midY),
                CGPoint(x: right, y: scrollFrame.midY)
            ]
            let startPoint = try XCTUnwrap(candidates.first { point in
                scrollFrame.insetBy(dx: 4, dy: 4).contains(point)
                && point.y < keyboardFrame.minY
                && !controls.contains { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }
            }, "Keyboard dismissal must start on observed scroll content outside text inputs and buttons")
            let endPoint = CGPoint(x: startPoint.x, y: endY)
            try require(right > left && scrollFrame.insetBy(dx: 4, dy: 4).contains(startPoint)
                        && keyboardFrame.insetBy(dx: 2, dy: 2).contains(endPoint)
                        && startPoint.y < keyboardFrame.minY && endPoint.y > keyboardFrame.minY + 24,
                        "A real downward scroll must cross the observed keyboard area")
            func frameValue(_ frame: CGRect) -> [String: CGFloat] {
                ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
            }
            let diagnostic: [String: Any] = [
                "run_id": runID, "case_id": caseID, "attempt": attempt + 1,
                "app_frame": frameValue(appFrame), "scroll_frame": frameValue(scrollFrame),
                "keyboard_frame": frameValue(keyboardFrame),
                "start": ["x": startPoint.x, "y": startPoint.y],
                "end": ["x": endPoint.x, "y": endPoint.y]
            ]
            print("STOCK_KEYBOARD_DRAG " + String(decoding: try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]), as: UTF8.self))
            // R3's center start fell inside the focused search TextField at A3,
            // where the gesture selected text. Start on observed non-control scroll
            // content and cross the keyboard; do not mutate focus or tap Return.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: startPoint.x - appFrame.minX, dy: startPoint.y - appFrame.minY))
            let end = origin.withOffset(CGVector(dx: endPoint.x - appFrame.minX, dy: endPoint.y - appFrame.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
            _ = keyboard.waitForNonExistence(timeout: 2)
        }
        try require(app.keyboards.count == 0, "The real interactive scroll must dismiss the keyboard")
    }

    @MainActor
    private func capture(_ phase: String, app: XCUIApplication) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let bytes = screenshot.pngRepresentation
        let image = screenshot.image
        let pixels = image.cgImage
        let source = CGImageSourceCreateWithData(bytes as CFData, nil)
        let properties: [String: Any]?
        if let source {
            properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        } else {
            properties = nil
        }
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? -1
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? -1
        func frame(_ r: CGRect) -> [String: CGFloat] {
            ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
        }
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let name = caseID + "-" + phase
        let geometry: [String: Any] = [
            "schema_version": 1, "run_id": runID, "case_id": caseID, "capture_name": name,
            "qa_bundle_identifier": bundleID, "app_frame": frame(app.frame),
            "window_frame": frame(app.windows.firstMatch.frame),
            "device_orientation": XCUIDevice.shared.orientation.rawValue,
            "pixel_width": pixelWidth, "pixel_height": pixelHeight,
            "pixel_metadata_basis": "original screenshot.pngRepresentation decoded by ImageIO",
            "cgimage_pixel_width": pixels?.width ?? -1, "cgimage_pixel_height": pixels?.height ?? -1,
            "image_point_width": image.size.width, "image_point_height": image.size.height,
            "image_scale": image.scale, "image_orientation": image.imageOrientation.rawValue,
            "png_sha256": hash, "png_bytes": bytes.count
        ]
        // Keep the exact original PNG and observed metadata even when a guard fails.
        // No redraw, resize, crop, orientation rewrite or image re-encoding occurs.
        let png = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.png")
        png.name = name; png.lifetime = .keepAlways; add(png)
        let text = XCTAttachment(string: String(decoding: try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys]), as: UTF8.self))
        text.name = "Stock UI geometry - " + name; text.lifetime = .keepAlways; add(text)
        // Preserve the observed native tree alongside the exact original PNG.
        // This is evidence capture only; it does not mutate focus, scroll or controls.
        let tree = app.debugDescription
        try require(!tree.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "The observed accessibility tree must be preserved for every capture")
        let accessibility: [String: Any] = [
            "schema_version": 1, "run_id": runID, "case_id": caseID, "capture_name": name,
            "qa_bundle_identifier": bundleID, "png_sha256": hash,
            "basis": "XCUIApplication.debugDescription from the actual foreground application",
            "accessibility_tree": tree
        ]
        let ax = XCTAttachment(string: String(decoding: try JSONSerialization.data(withJSONObject: accessibility,
            options: [.sortedKeys]), as: UTF8.self))
        ax.name = "Stock UI accessibility - " + name; ax.lifetime = .keepAlways; add(ax)
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        try require(bytes.starts(with: signature) && source.map { CGImageSourceGetCount($0) == 1 } == true,
                    "The original capture must be one decodable PNG")
        try require(pixelWidth == 750 && pixelHeight == 1334,
                    "Original PNG must be750x1334; observed\(pixelWidth)x\(pixelHeight), CGImage\(pixels?.width ?? -1)x\(pixels?.height ?? -1), UIImage\(image.size) scale\(image.scale)")
    }

    @MainActor
    private func finish(_ size: String, app: XCUIApplication) throws {
        let value: [String: Any] = [
            "schema_version": 1, "run_id": runID, "case_id": caseID, "dynamic_type": size,
            "bundle_id": bundleID, "actions": actions, "all_behavior_checks_completed": true
        ]
        let attachment = XCTAttachment(string: String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
        attachment.name = "Stock UI actions - " + caseID; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    private func browse(_ name: String, size: String) throws {
        let app = try start(name)
        defer { app.terminate() }
        let open = try unique(app.buttons, "fixture.openSheet")
        try require(fullyVisible(open, in: app), "Real fixture opener must be visible and hittable")
        open.tap(); actions.append("open-real-sheet")
        let done = try unique(app.buttons, "browse.done")
        try require(fullyVisible(done, in: app), "Real Done must remain inside viewport")
        let field = try unique(app.textFields, "browse.search")
        try reveal(field, in: app)
        try capture("presented", app: app)
        field.tap(); field.typeText("2222.SR")
        try require(field.value as? String == "2222.SR", "Real keyboard must enter the exact first query")
        try dismissKeyboard(in: app)
        let identity = app.descendants(matching: .any).matching(identifier: "browse.identity.2222.SR").firstMatch
        try reveal(identity, in: app)
        try require(app.descendants(matching: .any).matching(identifier: "browse.identity.2222.SR").count == 1,
                    "Matching catalog identity must be unique")
        actions.append("type-and-reveal-2222.SR")
        try capture("matching", app: app)

        // Replace the query using the actual user-facing clear control, not direct
        // UITextField mutation. This additionally verifies clear on a matching query.
        let clear = try unique(app.buttons, "browse.clear")
        try reveal(clear, in: app, up: false)
        clear.tap()
        try require(fieldIsEmptyValue(field),
                    "Actual clear must empty the first query")
        actions.append("clear-first-query")
        try reveal(field, in: app, up: false)
        field.tap(); field.typeText("NO-MATCH-SYNTHETIC-ZZZ")
        try require(field.value as? String == "NO-MATCH-SYNTHETIC-ZZZ", "Real keyboard must enter exact no-match query")
        try dismissKeyboard(in: app)
        let empty = app.descendants(matching: .any).matching(identifier: "browse.empty").firstMatch
        try reveal(empty, in: app)
        let label = app.staticTexts["No matching markets"]
        try require(fullyVisible(label, in: app), "No-match label must actually be visible")
        actions.append("type-and-reveal-no-match")
        try capture("no-match", app: app)
        let finalClear = try unique(app.buttons, "browse.clear")
        try reveal(finalClear, in: app, up: false)
        finalClear.tap()
        try require(fieldIsEmptyValue(field),
                    "Actual Clear search must empty the no-match query")
        try require(!empty.exists, "Empty state must disappear after clear")
        try reveal(field, in: app, up: false)
        try require(fieldIsEmptyValue(field), "Cleared search remains empty after the catalog scroll reset")
        let restored = app.descendants(matching: .any).matching(identifier: "browse.identity.2222.SR").firstMatch
        try reveal(restored, in: app)
        actions.append("clear-and-restore-catalog")
        try capture("cleared", app: app)
        try require(fullyVisible(done, in: app), "Done must be tappable after large-text interaction")
        done.tap()
        let completed = try unique(app.staticTexts, "qa.browse.completed")
        try require(completed.label == "sheetDismissed=true;symbolsUnchanged=true;addErrorAbsent=true",
                    "Derived real store state must be unchanged after dismiss")
        try require(!done.exists && fullyVisible(open, in: app), "The real sheet must be dismissed")
        actions.append("done-and-derived-store-readback")
        try capture("dismissed", app: app)
        try finish(size, app: app)
    }

    @MainActor
    private func onboarding(_ name: String, size: String) throws {
        let app = try start(name)
        defer { app.terminate() }
        let button = try unique(app.buttons, "onboarding.getStarted")
        try require(fullyVisible(button, in: app), "Get started must initially fit the native viewport")
        let firstStep = app.staticTexts.matching(identifier: "onboarding.step.1").firstMatch
        let initialFrame = firstStep.frame
        try capture("initial", app: app)
        let finalStep = app.staticTexts.matching(identifier: "onboarding.step.7").firstMatch
        try reveal(finalStep, in: app)
        try require(fullyVisible(finalStep, in: app), "The final numbered step must actually be reached")
        actions.append("reveal-final-numbered-step")
        let finalInstructions = app.staticTexts["Bring your saved records"]
        try reveal(finalInstructions, in: app)
        try require(fullyVisible(finalInstructions, in: app),
                    "The final instructions must actually be reached after the last numbered step")
        try require(!fullyVisible(firstStep, in: app) || firstStep.frame != initialFrame,
                    "The actual scroll content must move")
        actions.append("scroll-to-final-instructions")
        let restorePath = try unique(app.staticTexts, "onboarding.restorePath")
        try reveal(restorePath, in: app)
        try require(fullyVisible(restorePath, in: app), "The full backup navigation instructions must be reachable")
        try capture("restore-path", app: app)
        let restoreFile = try unique(app.staticTexts, "onboarding.restoreFile")
        try reveal(restoreFile, in: app)
        try require(fullyVisible(restoreFile, in: app), "The final backup selection instruction must be reachable")
        actions.append("read-full-final-instructions")
        try require(fullyVisible(button, in: app), "Get started must remain fully visible after scrolling")
        try capture("final-instructions", app: app)
        button.tap()
        let completed = try unique(app.staticTexts, "qa.onboarding.completed")
        try require(completed.label == "bindingDismissed=true;done=true",
                    "The production action must dismiss the binding and persist local completion")
        try require(!button.exists, "Onboarding must actually leave the screen")
        actions.append("get-started-and-derived-defaults-readback")
        try capture("completed", app: app)
        try finish(size, app: app)
    }
}

