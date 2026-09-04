import XCTest

#if targetEnvironment(macCatalyst)
@MainActor
final class ICloudAndMacFlowUITests: XCTestCase {
  func testDesktopSettingsExposeLocalDataExportWithoutRequiringSync() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-network-disabled", "-desktop-preview"]
    app.launch()

    if app.buttons["unlockButton"].waitForExistence(timeout: 3) {
      app.buttons["unlockButton"].tap()
    }
    app.staticTexts["设置"].tap()
    let exportButton = app.buttons["exportBirthdayDataButton"]
    for _ in 0..<5 where !exportButton.isHittable { app.swipeUp() }
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
    let deleteButton = app.buttons["从本机删除"]
    XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
    deleteButton.tap()
    XCTAssertTrue(app.buttons["确认删除"].waitForExistence(timeout: 3))
    XCTAssertTrue(
      app.staticTexts["确定删除“小满”吗？删除后将从本机生日列表移除。"].exists
    )
  }
}
#endif
