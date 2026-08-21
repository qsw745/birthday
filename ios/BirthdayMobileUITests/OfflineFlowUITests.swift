import XCTest

final class OfflineFlowUITests: XCTestCase {
  func testCreateSearchEditAndDeleteWithoutNetwork() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-network-disabled"]
    app.launch()

    XCTAssertTrue(
      app.staticTexts["离线也能完整使用"].waitForExistence(timeout: 5),
      "UI 测试启动必须仍然显示首次引导"
    )
    app.buttons["继续"].tap()
    app.buttons["暂不开启"].tap()

    let unlockButton = app.buttons["unlockButton"]
    if unlockButton.waitForExistence(timeout: 2) {
      unlockButton.tap()
    }

    let addButtons = app.buttons.matching(identifier: "addBirthdayButton")
    XCTAssertEqual(addButtons.count, 1, "当前页面必须只有一个规范的添加生日入口")
    let addButton = addButtons.element
    XCTAssertTrue(addButton.waitForExistence(timeout: 3))
    addButton.tap()

    let nameField = app.textFields["birthdayNameField"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 3))
    nameField.tap()
    nameField.typeText("妈妈")
    app.buttons["saveBirthdayButton"].tap()

    app.tabBars.buttons["全部"].tap()
    XCTAssertTrue(app.staticTexts["妈妈"].waitForExistence(timeout: 3))

    let searchField = app.searchFields["birthdaySearchField"]
    XCTAssertTrue(searchField.waitForExistence(timeout: 3))
    searchField.tap()
    searchField.typeText("妈妈")
    app.staticTexts["妈妈"].tap()

    XCTAssertTrue(nameField.waitForExistence(timeout: 3))
    nameField.clearAndEnterText("妈妈更新")
    app.buttons["saveBirthdayButton"].tap()
    XCTAssertTrue(app.staticTexts["妈妈更新"].waitForExistence(timeout: 3))

    app.staticTexts["妈妈更新"].tap()
    let deleteButton = app.buttons["deleteBirthdayButton"]
    XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
    deleteButton.tap()
    XCTAssertTrue(
      app.staticTexts["确定删除“妈妈更新”吗？删除后只会从本机隐藏。服务器同步尚未启用。"]
        .waitForExistence(timeout: 3)
    )
    app.buttons["确认删除"].tap()
    XCTAssertTrue(app.staticTexts["妈妈更新"].waitForNonExistence(timeout: 3))
  }
}

extension XCUIElement {
  func clearAndEnterText(_ text: String) {
    tap()
    if let current = value as? String, !current.isEmpty {
      typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    typeText(text)
  }
}
