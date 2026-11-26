import XCTest

final class FlowUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(language: String = "zh-Hans", reset: Bool = true, extras: [String] = []) {
        app.launchArguments = ["-ui-testing", "-fixtures", "-AppleLanguages", "(\(language))", "-AppleLocale", "en_US"]
            + (reset ? ["-reset"] : []) + extras
        app.launchEnvironment["PDFMERGE_TEST_PASTE"] = "\nPDFMERGE1:eyJ2ZXJzaW9uIjoxLCJzbG90cyI6WyJtYXRlcmlhbCJdfQ\n"
        app.launch()
        XCTAssertTrue(app.buttons["home.pick"].waitForExistence(timeout: 15))
    }

    private func tap(_ id: String, scroll: Bool = false) {
        let button = app.buttons[id].firstMatch
        if scroll {
            for index in 0..<12 {
                if button.exists && button.isHittable { break }
                if index < 6 { app.swipeUp() } else { app.swipeDown() }
            }
        }
        XCTAssertTrue(button.waitForExistence(timeout: 8), id)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed, id)
        button.tap()
    }

    private func choose(_ indices: [Int], from button: String = "home.pick") {
        tap(button, scroll: button.hasPrefix("batch.slot"))
        indices.forEach { tap("fixtures.file.\($0)") }
        tap("fixtures.open")
    }

    private func drag(_ source: XCUIElement, to target: XCUIElement) {
        let endpointsReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            source.exists && source.isHittable && source.isEnabled
                && target.exists && target.isHittable && target.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [endpointsReady], timeout: 12), .completed,
                       "Drag endpoints not ready: \(source) → \(target)")
        let center = CGVector(dx: 0.5, dy: 0.5)
        source.coordinate(withNormalizedOffset: center).press(
            forDuration: 1.2, thenDragTo: target.coordinate(withNormalizedOffset: center),
            withVelocity: .slow, thenHoldForDuration: 0.5
        )
    }

    private func assertLabel(_ label: String, on element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 8), .completed, "Expected \(label) on \(element)", file: file, line: line)
    }

    private func shareRequested() {
        XCTAssertTrue(app.staticTexts["share.requested"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["Save to Files"].exists)
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testImportCancelAppendRotateRemoveUndoAndShare() {
        launch(language: "en")
        tap("home.pick")
        tap("fixtures.cancel")
        XCTAssertTrue(app.buttons["home.pick"].exists)
        XCTAssertFalse(app.staticTexts["purchase.title"].exists)
        choose([0])
        choose([1], from: "edit.add")
        tap("edit.page.2")
        tap("edit.rotate")
        tap("edit.removePage")
        XCTAssertTrue(app.buttons["edit.undo"].isEnabled)
        tap("edit.undo")
        XCTAssertTrue(app.buttons["edit.page.2"].exists)
        tap("edit.generate")
        shareRequested()
        tap("work.back")
        tap("home.recent.0", scroll: true)
        XCTAssertFalse(app.staticTexts["share.requested"].exists)
        tap("result.share")
        shareRequested()
    }

    func testSavePDFPagesToPhotosWithoutWritingPhotoLibrary() {
        launch(language: "en")
        choose([0])
        tap("edit.photos.0")
        assertLabel("Save All Pages", on: app.buttons["photo.save"])
        tap("photo.page.1")
        assertLabel("Save Selected Pages", on: app.buttons["photo.save"])
        tap("photo.save")
        assertLabel("Images saved to Photos: 1", on: app.staticTexts["photo.saved"])
        tap("photo.close")

        tap("edit.generate")
        tap("result.photos", scroll: true)
        tap("photo.save")
        assertLabel("Images saved to Photos: 2", on: app.staticTexts["photo.saved"])

        app.terminate()
        launch(language: "en", reset: false, extras: ["-expired"])
        tap("home.recent.0", scroll: true)
        tap("result.photos", scroll: true)
        XCTAssertTrue(app.staticTexts["purchase.expired"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["photo.save"].exists)
    }

    func testNewMergeCanShareOrderCardDirectly() {
        launch(language: "en")
        choose([0, 1])
        tap("edit.shareOrder")
        shareRequested()
        XCTAssertTrue(app.staticTexts["result.name"].exists)
        XCTAssertFalse(app.images["card.preview"].exists)
        tap("result.card", scroll: true)
        XCTAssertTrue(app.images["card.preview"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.images["card.preview"].label.contains("#"))
    }

    func testCrossFileDragRegroupAndUndo() {
        launch(language: "en")
        choose([0, 1, 2])
        let mixedMessage = "Pages are mixed. Moving a file groups them again."
        let mixed = app.staticTexts.matching(NSPredicate(format: "identifier == %@", "edit.mixed")).firstMatch
        let mixedTexts = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "edit.mixed", mixedMessage)
        )
        let secondPage = app.buttons["edit.page.1"]
        let firstFile = app.buttons["edit.file.0"]

        func assertPageOrder(_ names: [String], line: UInt = #line) {
            for (index, name) in names.enumerated() {
                assertLabel("\(index + 1) · \(name).pdf", on: app.buttons["edit.page.\(index)"], line: line)
            }
        }

        let dropped = NSPredicate(format: "exists == true AND label == %@", "2 · Attachment.pdf")
        for _ in 0..<3 {
            drag(app.buttons["edit.page.3"], to: secondPage)
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: dropped, object: secondPage)], timeout: 4) == .completed { break }
        }
        assertLabel("2 · Attachment.pdf", on: secondPage)
        assertLabel(mixedMessage, on: mixed)

        let attachmentFile = app.staticTexts["Attachment.pdf"]
        XCTAssertTrue(attachmentFile.waitForExistence(timeout: 8))
        attachmentFile.press(forDuration: 1)
        let moveToTop = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "edit.file.moveToTop", "Move to Top")
        ).firstMatch
        XCTAssertTrue(moveToTop.waitForExistence(timeout: 8))
        moveToTop.tap()
        assertLabel("Move Attachment.pdf", on: firstFile)
        assertPageOrder(["Attachment", "Attachment", "Attachment", "Application", "Application", "Receipt"])
        let regrouped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in mixedTexts.count == 0 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [regrouped], timeout: 8), .completed,
                       "Mixed notice still matched after regrouping: \(mixedTexts.debugDescription)")

        tap("edit.undo")
        assertLabel("Move Application.pdf", on: firstFile)
        assertPageOrder(["Application", "Attachment", "Application", "Receipt", "Attachment", "Attachment"])
        assertLabel(mixedMessage, on: mixed)
    }

    func testBadInputBlocksOutputAndDraftPersists() {
        launch(extras: ["-invalid-fixture"])
        choose([0, 3])
        XCTAssertTrue(app.buttons["edit.remove.1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["edit.generate"].isEnabled)
        tap("edit.remove.1")
        tap("work.back")
        app.terminate()
        launch(reset: false)
        tap("home.resume")
        tap("edit.generate")
        XCTAssertTrue(app.buttons["result.share"].waitForExistence(timeout: 10))
    }

    func testExpiredKeepsHistoryAndTemplateButGatesBatch() {
        launch(language: "en", extras: ["-sample-template"])
        choose([0, 1])
        tap("edit.generate")
        XCTAssertTrue(app.buttons["result.share"].waitForExistence(timeout: 10))
        app.terminate()
        launch(language: "en", reset: false, extras: ["-expired", "-sample-template"])
        tap("home.recent.0", scroll: true)
        tap("result.rename")
        let dialog = app.alerts.firstMatch
        let field = dialog.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let length = (field.value as? String)?.count ?? 35
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length + 2) + "Packet")
        dialog.buttons["Save"].tap()
        XCTAssertEqual(app.staticTexts["result.name"].label, "Packet.pdf")
        tap("result.share")
        shareRequested()
        tap("work.back")
        tap("home.templates")
        XCTAssertTrue(app.buttons["template.slot.0"].waitForExistence(timeout: 10))
        tap("template.batch", scroll: true)
        XCTAssertTrue(app.staticTexts["purchase.expired"].waitForExistence(timeout: 10))
    }

    func testTemplateCodeMilestoneAndShares() {
        launch()
        tap("home.templates")
        tap("template.paste")
        XCTAssertTrue(app.buttons["template.slot.0"].waitForExistence(timeout: 10))
        choose([0], from: "template.slot.0")
        tap("template.apply", scroll: true)
        for index in 1...5 {
            if index > 1 { tap("home.resume"); tap("edit.page.0"); tap("edit.rotate") }
            tap("edit.generate")
            shareRequested()
            if index < 5 { tap("work.back") }
        }
        tap("result.milestone", scroll: true)
        XCTAssertTrue(app.images["card.preview"].waitForExistence(timeout: 15))
        tap("card.share")
        shareRequested()
        tap("card.done")
        tap("result.card", scroll: true)
        tap("card.template", scroll: true)
        shareRequested()
    }

    func testTemplateFileBatchPartialFailureAndRetry() {
        launch(language: "en", extras: ["-invalid-fixture"])
        tap("home.templates")
        choose([0], from: "template.openFile")
        tap("template.batch", scroll: true)
        choose([0], from: "batch.slot.0.0")
        tap("batch.add", scroll: true)
        choose([3], from: "batch.slot.1.0")
        tap("batch.generate", scroll: true)
        XCTAssertTrue(app.buttons["batch.output.0"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["batch.retry.1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["batch.output.1"].exists)
        choose([1], from: "batch.slot.1.0")
        tap("batch.retry.1", scroll: true)
        tap("batch.output.1", scroll: true)
        tap("batch.share")
        shareRequested()
    }

    private func store(_ language: String) {
        launch(language: language, extras: ["-sample-template", "-store-shots"])
        tap("home.pick")
        for index in 0...2 { tap("fixtures.file.\(index)") }
        screenshot("store-\(language)-01-select")
        tap("fixtures.open")
        XCTAssertTrue(app.buttons["edit.page.5"].waitForExistence(timeout: 15))
        screenshot("store-\(language)-02-arrange")
        tap("edit.generate")
        XCTAssertTrue(app.buttons["result.share"].waitForExistence(timeout: 12))
        screenshot("store-\(language)-03-result")
        tap("result.card", scroll: true)
        XCTAssertTrue(app.images["card.preview"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.images["card.preview"].isHittable)
        screenshot("store-\(language)-05-card")
        tap("card.done")
        tap("work.back")
        tap("home.templates")
        let preview = app.staticTexts["template.namingPreview"]
        for _ in 0..<4 {
            if preview.exists && preview.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(preview.waitForExistence(timeout: 8))
        screenshot("store-\(language)-04-template")
    }

    func testStoreSimplified() { store("zh-Hans") }
    func testStoreTraditional() { store("zh-Hant") }
    func testStoreEnglish() { store("en") }
    func testStoreJapanese() { store("ja") }

    func testPaidScreenshot() {
        launch(extras: ["-paywall", "-expired"])
        XCTAssertTrue(app.staticTexts["purchase.expired"].waitForExistence(timeout: 12))
        screenshot("paid-01-paywall")
    }
}
