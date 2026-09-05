import XCTest

#if targetEnvironment(macCatalyst)
@MainActor
final class ICloudAndMacFlowUITests: XCTestCase {
#if CLOUDKIT_PRODUCTION_SMOKE
  private let productionCloudKitPhoneName = "云端验收-68F2A"
  private let productionCloudKitMacName = "云端验收-68F2B"

  func testProductionCloudKitReceivesIPhoneFixtureAndEditsItOnMac() {
    let app = launchProductionCloudKitSmoke()
    XCTAssertTrue(app.descendants(matching: .any)["macSidebar"].waitForExistence(timeout: 10))
    XCTAssertTrue(waitForCloudSynchronization(in: app, timeout: 30))

    app.staticTexts["全部生日"].tap()
    let phoneRecord = app.staticTexts[productionCloudKitPhoneName].firstMatch
    XCTAssertTrue(phoneRecord.waitForExistence(timeout: 15))
    phoneRecord.tap()
    let editButton = app.buttons["编辑"]
    XCTAssertTrue(editButton.waitForExistence(timeout: 5))
    editButton.tap()

    let nameField = app.textFields["birthdayNameField"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 5))
    nameField.clearAndEnterText(productionCloudKitMacName)
    app.buttons["saveBirthdayButton"].tap()
    XCTAssertTrue(app.staticTexts[productionCloudKitMacName].firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(
      forceCloudSynchronization(in: app, timeout: 30),
      "CloudKit 同步诊断：\(app.descendants(matching: .any)["cloudSyncDiagnostics"].label)"
    )
  }

  func testProductionCloudKitReceivesDeletionTombstoneOnMac() {
    let app = launchProductionCloudKitSmoke()
    XCTAssertTrue(app.descendants(matching: .any)["macSidebar"].waitForExistence(timeout: 10))
    XCTAssertTrue(waitForCloudSynchronization(in: app, timeout: 30))

    app.staticTexts["全部生日"].tap()
    XCTAssertFalse(app.staticTexts[productionCloudKitPhoneName].firstMatch.exists)
    XCTAssertFalse(app.staticTexts[productionCloudKitMacName].firstMatch.exists)
  }
#endif

  func testDesktopSettingsExposeLocalDataExportWithoutRequiringSync() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-network-disabled", "-desktop-preview"]
    app.launch()

    if app.buttons["unlockButton"].waitForExistence(timeout: 3) {
      app.buttons["unlockButton"].tap()
    }
    app.staticTexts["设置"].tap()
    let exportButton = app.buttons["exportBirthdayDataButton"]
    let settingsList = app.collectionViews.firstMatch
    for _ in 0..<5 where !exportButton.isHittable { settingsList.swipeUp() }
    XCTAssertTrue(exportButton.waitForExistence(timeout: 3))
    XCTAssertTrue(exportButton.isEnabled)
  }

  func testDesktopLayoutExposesThreeColumnsToolbarContextMenuAndDeleteConfirmation() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-network-disabled", "-desktop-preview"]
    app.launch()

    if app.buttons["unlockButton"].waitForExistence(timeout: 3) {
      app.buttons["unlockButton"].tap()
    }
    XCTAssertTrue(app.descendants(matching: .any)["macSidebar"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.descendants(matching: .any)["macPrimaryContent"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["macDetailColumn"].exists)
    XCTAssertTrue(app.buttons["macAddBirthdayToolbarButton"].exists)

    app.staticTexts["全部生日"].tap()
    let recordID = "55555555-5555-4555-8555-555555555555"
    let row = app.descendants(matching: .any)["desktopBirthdayRow-\(recordID)"]
    XCTAssertTrue(row.waitForExistence(timeout: 3))
    row.tap()
    XCTAssertTrue(app.staticTexts["生日详情"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["小满"].exists)

    row.rightClick()
    let deleteButton = app.menuItems["从本机删除"]
    XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
    deleteButton.tap()
    XCTAssertTrue(app.buttons["确认删除"].waitForExistence(timeout: 3))
    XCTAssertTrue(
      app.staticTexts["确定删除“小满”吗？删除后将从本机生日列表移除。"].exists
    )
  }
#if CLOUDKIT_PRODUCTION_SMOKE
  private func launchProductionCloudKitSmoke() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-cloudkit-production-smoke"]
    app.launch()
    if app.buttons["unlockButton"].waitForExistence(timeout: 3) {
      app.buttons["unlockButton"].tap()
    }
    return app
  }

  private func waitForCloudSynchronization(
    in app: XCUIApplication,
    timeout: TimeInterval
  ) -> Bool {
    app.staticTexts["设置"].tap()
    let status = app.descendants(matching: .any)["icloudSyncStatus"]
    let settingsList = app.collectionViews.firstMatch
    for _ in 0..<5 where !status.exists { settingsList.swipeUp() }
    guard status.waitForExistence(timeout: 5) else { return false }
    let synchronized = NSPredicate(format: "label CONTAINS %@", "已同步")
    let expectation = XCTNSPredicateExpectation(predicate: synchronized, object: status)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func forceCloudSynchronization(
    in app: XCUIApplication,
    timeout: TimeInterval
  ) -> Bool {
    app.staticTexts["设置"].tap()
    let refresh = app.buttons["manualCloudSyncButton"]
    let settingsList = app.collectionViews.firstMatch
    for _ in 0..<5 where !refresh.exists { settingsList.swipeUp() }
    guard refresh.waitForExistence(timeout: 5), refresh.isEnabled else { return false }
    let diagnostics = app.descendants(matching: .any)["cloudSyncDiagnostics"]
    guard diagnostics.waitForExistence(timeout: 5) else { return false }
    let previousCompletion = diagnosticInteger("completed", in: diagnostics.label) ?? -1
    refresh.tap()

    let completed = NSPredicate { object, _ in
      guard let element = object as? XCUIElement else { return false }
      return (self.diagnosticInteger("completed", in: element.label) ?? -1)
        > previousCompletion
    }
    let completionExpectation = XCTNSPredicateExpectation(predicate: completed, object: diagnostics)
    guard XCTWaiter.wait(for: [completionExpectation], timeout: timeout) == .completed else {
      return false
    }
    return diagnostics.label.contains("pending=0;status=synchronized")
  }

  private func diagnosticInteger(_ key: String, in summary: String) -> Int? {
    summary
      .split(separator: ";")
      .first { $0.hasPrefix("\(key)=") }
      .flatMap { Int($0.dropFirst(key.count + 1)) }
  }
#endif
}

private extension XCUIElement {
  func clearAndEnterText(_ text: String) {
    tap()
    if let current = value as? String, !current.isEmpty {
      typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    typeText(text)
  }
}
#endif
