import XCTest

@MainActor
final class OfflineFlowUITests: XCTestCase {
#if CLOUDKIT_PRODUCTION_SMOKE
  private let productionCloudKitPhoneName = "云端验收-68F2A"
  private let productionCloudKitMacName = "云端验收-68F2B"

  func testProductionCloudKitCreatesIsolatedFixtureOnIPhone() {
    let app = launchProductionCloudKitSmoke()
    XCTAssertTrue(app.buttons["addBirthdayButton"].waitForExistence(timeout: 10))
    XCTAssertTrue(waitForCloudSynchronization(in: app, timeout: 30))

    app.tabBars.buttons["全部"].tap()
    if !app.staticTexts[productionCloudKitPhoneName].exists {
      app.tabBars.buttons["日历"].tap()
      app.buttons["addBirthdayButton"].tap()
      let nameField = app.textFields["birthdayNameField"]
      XCTAssertTrue(nameField.waitForExistence(timeout: 5))
      nameField.tap()
      nameField.typeText(productionCloudKitPhoneName)
      app.buttons["saveBirthdayButton"].tap()
      if app.buttons["从明年开始"].waitForExistence(timeout: 1) {
        app.buttons["从明年开始"].tap()
      }
    }

    app.tabBars.buttons["全部"].tap()
    XCTAssertTrue(app.staticTexts[productionCloudKitPhoneName].waitForExistence(timeout: 10))
    XCTAssertTrue(
      forceCloudSynchronization(in: app, timeout: 30),
      "CloudKit 同步诊断：\(app.descendants(matching: .any)["cloudSyncDiagnostics"].label)"
    )
  }

  func testProductionCloudKitReceivesMacEditAndDeletesFixtureOnIPhone() {
    let app = launchProductionCloudKitSmoke()
    XCTAssertTrue(app.buttons["addBirthdayButton"].waitForExistence(timeout: 10))
    XCTAssertTrue(waitForCloudSynchronization(in: app, timeout: 30))

    app.tabBars.buttons["全部"].tap()
    let editedRecord = app.staticTexts[productionCloudKitMacName]
    XCTAssertTrue(editedRecord.waitForExistence(timeout: 15))
    editedRecord.tap()
    let deleteButton = app.buttons["deleteBirthdayButton"]
    XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
    deleteButton.tap()
    XCTAssertTrue(app.buttons["确认删除"].waitForExistence(timeout: 3))
    app.buttons["确认删除"].tap()
    XCTAssertTrue(editedRecord.waitForNonExistence(timeout: 10))
    XCTAssertTrue(
      forceCloudSynchronization(in: app, timeout: 30),
      "CloudKit 同步诊断：\(app.descendants(matching: .any)["cloudSyncDiagnostics"].label)"
    )
  }

  func testProductionCloudKitRemovesAllIsolatedFixturesOnIPhone() {
    let app = launchProductionCloudKitSmoke()
    XCTAssertTrue(app.buttons["addBirthdayButton"].waitForExistence(timeout: 10))
    XCTAssertTrue(waitForCloudSynchronization(in: app, timeout: 30))

    app.tabBars.buttons["全部"].tap()
    for _ in 0..<20 {
      let macRecords = app.staticTexts.matching(identifier: productionCloudKitMacName)
      let phoneRecords = app.staticTexts.matching(identifier: productionCloudKitPhoneName)
      let record = macRecords.count > 0 ? macRecords.firstMatch : phoneRecords.firstMatch
      guard record.exists else { break }
      let previousCount = macRecords.count + phoneRecords.count

      record.tap()
      let deleteButton = app.buttons["deleteBirthdayButton"]
      XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
      deleteButton.tap()
      XCTAssertTrue(app.buttons["确认删除"].waitForExistence(timeout: 3))
      app.buttons["确认删除"].tap()

      let recordRemoved = NSPredicate { _, _ in
        macRecords.count + phoneRecords.count < previousCount
      }
      let removalExpectation = XCTNSPredicateExpectation(predicate: recordRemoved, object: app)
      XCTAssertEqual(XCTWaiter.wait(for: [removalExpectation], timeout: 10), .completed)
    }

    XCTAssertEqual(app.staticTexts.matching(identifier: productionCloudKitMacName).count, 0)
    XCTAssertEqual(app.staticTexts.matching(identifier: productionCloudKitPhoneName).count, 0)
    XCTAssertTrue(
      forceCloudSynchronization(in: app, timeout: 30),
      "CloudKit 同步诊断：\(app.descendants(matching: .any)["cloudSyncDiagnostics"].label)"
    )
  }
#endif

  func testCloudKitOnboardingAndSettingsRemainLocalFirstWithoutNetwork() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-network-disabled", "-cloudkit-sync"]
    app.launch()

    XCTAssertTrue(app.staticTexts["离线也能完整使用"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "iCloud 私有空间同步")
      ).firstMatch.exists
    )
    app.buttons["继续"].tap()
    app.buttons["暂不开启"].tap()
    if app.buttons["unlockButton"].waitForExistence(timeout: 2) {
      app.buttons["unlockButton"].tap()
    }
    XCTAssertTrue(app.buttons["addBirthdayButton"].waitForExistence(timeout: 5))

    app.tabBars.buttons["设置"].tap()
    let cloudToggle = app.switches["icloudSyncToggle"]
    for _ in 0..<4 where !cloudToggle.isHittable { app.swipeUp() }
    XCTAssertTrue(cloudToggle.waitForExistence(timeout: 3))
    XCTAssertTrue(cloudToggle.isHittable)
    cloudToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    let status = app.descendants(matching: .any)["icloudSyncStatus"]
    XCTAssertTrue(status.waitForExistence(timeout: 3))
    XCTAssertTrue(
      status.label.contains("同步已关闭"),
      "关闭后状态不正确：\(status.label)，开关值：\(String(describing: cloudToggle.value))"
    )
    cloudToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    let refresh = app.buttons["manualCloudSyncButton"]
    XCTAssertTrue(refresh.waitForExistence(timeout: 3))
    refresh.tap()
    XCTAssertFalse(app.buttons["bindFromSettingsButton"].exists)
  }

  func testCloudKitAccountChangeRequiresExplicitConfirmation() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-ui-testing", "-network-disabled", "-cloudkit-sync", "-cloud-account-change",
    ]
    app.launch()

    XCTAssertTrue(app.staticTexts["离线也能完整使用"].waitForExistence(timeout: 5))
    app.buttons["继续"].tap()
    app.buttons["暂不开启"].tap()
    if app.buttons["unlockButton"].waitForExistence(timeout: 2) {
      app.buttons["unlockButton"].tap()
    }
    app.tabBars.buttons["设置"].tap()

    let confirmation = app.buttons["confirmCloudAccountChangeButton"]
    for _ in 0..<4 where !confirmation.isHittable { app.swipeUp() }
    XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["cancelCloudAccountChangeButton"].exists)
    confirmation.tap()
    let merge = app.buttons["保留本机数据并安全合并"]
    XCTAssertTrue(merge.waitForExistence(timeout: 3))
    merge.tap()
    let status = app.descendants(matching: .any)["icloudSyncStatus"]
    XCTAssertTrue(status.waitForExistence(timeout: 3))
    XCTAssertTrue(status.label.contains("已同步"))
  }

  func testStoreReleaseIsLocalOnlyFromOnboardingThroughSettings() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-ui-testing",
      "-network-disabled",
      "-store-release-local-only",
    ]
    app.launch()

    XCTAssertTrue(app.staticTexts["离线也能完整使用"].waitForExistence(timeout: 5))
    app.buttons["继续"].tap()
    app.buttons["暂不开启"].tap()

    if app.buttons["unlockButton"].waitForExistence(timeout: 2) {
      app.buttons["unlockButton"].tap()
    }
    XCTAssertTrue(app.buttons["addBirthdayButton"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.tabBars.buttons["冲突"].exists)

    app.tabBars.buttons["设置"].tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["localOnlyStorageRow"].waitForExistence(timeout: 3)
    )
    XCTAssertFalse(app.buttons["bindFromSettingsButton"].exists)
    XCTAssertFalse(app.buttons["manualSyncButton"].exists)
    XCTAssertFalse(app.buttons["stopSyncButton"].exists)
  }

  func testTransportCleanupFailureKeepsRetryAndExplicitResumeActionsVisible() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-ui-testing",
      "-network-disabled",
      "-transport-cleanup-failure",
    ]
    app.launch()

    XCTAssertTrue(app.staticTexts["离线也能完整使用"].waitForExistence(timeout: 5))
    app.buttons["继续"].tap()
    app.buttons["暂不开启"].tap()
    app.buttons["skipServerBindingButton"].tap()
    if app.buttons["unlockButton"].waitForExistence(timeout: 2) {
      app.buttons["unlockButton"].tap()
    }
    app.tabBars.buttons["设置"].tap()

    let stopSyncButton = app.buttons["stopSyncButton"]
    for _ in 0..<4 where !stopSyncButton.exists {
      app.swipeUp()
    }
    XCTAssertTrue(stopSyncButton.waitForExistence(timeout: 3))
    stopSyncButton.tap()
    app.buttons["撤销此设备并停止"].tap()
    XCTAssertTrue(app.staticTexts["服务器暂时不可达"].waitForExistence(timeout: 3))
    app.buttons["仍要停止本机同步"].tap()

    let retryCleanupButton = app.buttons["retryCredentialCleanupButton"]
    let resumeSyncButton = app.buttons["resumeSyncAfterCleanupFailureButton"]
    for _ in 0..<4 where !retryCleanupButton.exists {
      app.swipeUp()
    }
    XCTAssertTrue(retryCleanupButton.waitForExistence(timeout: 3))
    XCTAssertTrue(resumeSyncButton.waitForExistence(timeout: 3))
    resumeSyncButton.tap()

    for _ in 0..<4 where !stopSyncButton.exists {
      app.swipeUp()
    }
    XCTAssertTrue(stopSyncButton.waitForExistence(timeout: 3))
    XCTAssertFalse(retryCleanupButton.exists)
    XCTAssertFalse(resumeSyncButton.exists)
  }

  func testLocalOnlySettingsExposeBindingWithoutDestructiveDeviceActions() {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-testing", "-network-disabled"]
    app.launch()

    XCTAssertTrue(app.staticTexts["离线也能完整使用"].waitForExistence(timeout: 5))
    app.buttons["继续"].tap()
    app.buttons["暂不开启"].tap()
    app.buttons["skipServerBindingButton"].tap()
    if app.buttons["unlockButton"].waitForExistence(timeout: 2) {
      app.buttons["unlockButton"].tap()
    }

    app.tabBars.buttons["设置"].tap()

    XCTAssertTrue(app.staticTexts["仅本地使用"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["bindFromSettingsButton"].exists)
    XCTAssertFalse(app.buttons["stopSyncButton"].exists)
    XCTAssertFalse(app.buttons["revokeDeviceButton"].exists)
  }

  func testBoundDeviceReviewsEveryDuplicateBeforeAtomicSnapshotImport() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-ui-testing",
      "-network-disabled",
      "-snapshot-import-preview",
    ]
    app.launch()

    XCTAssertTrue(app.staticTexts["离线也能完整使用"].waitForExistence(timeout: 5))
    app.buttons["继续"].tap()
    app.buttons["暂不开启"].tap()

    app.textFields["serverUsernameField"].tap()
    app.textFields["serverUsernameField"].typeText("admin")
    app.secureTextFields["serverPasswordField"].tap()
    app.secureTextFields["serverPasswordField"].typeText("ui-test-secret")
    app.buttons["bindServerButton"].tap()

    XCTAssertTrue(
      app.staticTexts["首次导入预览"].waitForExistence(timeout: 5),
      "凭据保存后应独立读取快照并进入预览"
    )
    XCTAssertTrue(app.staticTexts["服务器中有 3 条生日"].exists)
    XCTAssertTrue(app.staticTexts["发现 2 组可能重复"].exists)

    let importButton = app.buttons["importSnapshotButton"]
    XCTAssertTrue(importButton.exists)
    XCTAssertEqual(importButton.label, "导入 3 条生日")
    XCTAssertFalse(importButton.isEnabled, "所有重复项未决策前禁止写入")

    let keepBoth = app.buttons["keepBothDuplicateButton"].firstMatch
    XCTAssertTrue(keepBoth.exists)
    XCTAssertTrue(app.buttons["useRemoteDuplicateButton"].firstMatch.exists)
    keepBoth.tap()
    XCTAssertEqual(
      app.buttons.matching(identifier: "keepBothDuplicateButton")
        .matching(NSPredicate(format: "value == %@", "已选择")).count,
      2,
      "同一本地 UUID 的所有远端候选必须共享一个组级决定"
    )
    XCTAssertTrue(importButton.isEnabled)
    importButton.tap()

    let unlockButton = app.buttons["unlockButton"]
    if unlockButton.waitForExistence(timeout: 2) {
      unlockButton.tap()
    }
    XCTAssertTrue(
      app.buttons["addBirthdayButton"].waitForExistence(timeout: 5),
      "原子导入成功后应完成引导并打开月历"
    )
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "爸爸")).firstMatch
        .waitForExistence(timeout: 3),
      "服务器未提供公历日期时，也应本地计算并显示在首屏月历"
    )
    app.tabBars.buttons["全部"].tap()
    XCTAssertTrue(app.staticTexts["妈妈"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["爸爸"].waitForExistence(timeout: 3))
  }

  func testSnapshotFailureRetriesAfterBindingWithoutPasswordOrLocalWrites() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-ui-testing",
      "-network-disabled",
      "-snapshot-import-preview",
      "-snapshot-first-load-fails",
    ]
    app.launch()

    XCTAssertTrue(app.staticTexts["离线也能完整使用"].waitForExistence(timeout: 5))
    app.buttons["继续"].tap()
    app.buttons["暂不开启"].tap()
    app.textFields["serverUsernameField"].tap()
    app.textFields["serverUsernameField"].typeText("admin")
    app.secureTextFields["serverPasswordField"].tap()
    app.secureTextFields["serverPasswordField"].typeText("ui-test-secret")
    app.buttons["bindServerButton"].tap()

    XCTAssertTrue(
      app.staticTexts["暂时无法读取服务器快照，本机资料未改变。"]
        .waitForExistence(timeout: 5)
    )
    XCTAssertFalse(app.secureTextFields["serverPasswordField"].exists)
    app.buttons["retrySnapshotPreviewButton"].tap()

    XCTAssertTrue(app.staticTexts["首次导入预览"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["发现 2 组可能重复"].exists)
    XCTAssertFalse(app.buttons["importSnapshotButton"].isEnabled)
  }

  func testCommittedSnapshotRefreshFailureReloadsWithoutReimporting() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-ui-testing",
      "-network-disabled",
      "-snapshot-import-preview",
      "-snapshot-first-refresh-fails",
    ]
    app.launch()

    XCTAssertTrue(app.staticTexts["离线也能完整使用"].waitForExistence(timeout: 5))
    app.buttons["继续"].tap()
    app.buttons["暂不开启"].tap()
    app.textFields["serverUsernameField"].tap()
    app.textFields["serverUsernameField"].typeText("admin")
    app.secureTextFields["serverPasswordField"].tap()
    app.secureTextFields["serverPasswordField"].typeText("ui-test-secret")
    app.buttons["bindServerButton"].tap()

    XCTAssertTrue(app.staticTexts["首次导入预览"].waitForExistence(timeout: 5))
    app.buttons["keepBothDuplicateButton"].firstMatch.tap()
    app.buttons["importSnapshotButton"].tap()

    XCTAssertTrue(
      app.staticTexts["导入已完成，但界面刷新失败。请重新载入已导入资料。"]
        .waitForExistence(timeout: 5)
    )
    XCTAssertFalse(app.buttons["importSnapshotButton"].exists)
    app.buttons["retryImportedSnapshotRefreshButton"].tap()

    let unlockButton = app.buttons["unlockButton"]
    if unlockButton.waitForExistence(timeout: 2) {
      unlockButton.tap()
    }
    XCTAssertTrue(app.buttons["addBirthdayButton"].waitForExistence(timeout: 5))
  }

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

    XCTAssertTrue(
      app.staticTexts["连接服务器（可选）"].waitForExistence(timeout: 3),
      "通知选择后必须进入可跳过的服务器绑定步骤"
    )
    XCTAssertTrue(app.textFields["serverUsernameField"].exists)
    XCTAssertTrue(app.secureTextFields["serverPasswordField"].exists)
    XCTAssertTrue(app.textFields["serverDeviceNameField"].exists)
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label == %@", "绑定并查看预览")).firstMatch.exists,
      "绑定按钮必须准确说明成功后只进入预览"
    )
    app.secureTextFields["serverPasswordField"].tap()
    app.secureTextFields["serverPasswordField"].typeText("ui-test-secret")
    app.buttons["skipServerBindingButton"].tap()

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
      app.staticTexts["确定删除“妈妈更新”吗？删除后将从本机生日列表移除。"]
        .waitForExistence(timeout: 3)
    )
    app.buttons["确认删除"].tap()
    XCTAssertTrue(app.staticTexts["妈妈更新"].waitForNonExistence(timeout: 3))
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
    app.tabBars.buttons["设置"].tap()
    let status = app.descendants(matching: .any)["icloudSyncStatus"]
    guard status.waitForExistence(timeout: 5) else { return false }
    let synchronized = NSPredicate(format: "label CONTAINS %@", "已同步")
    let expectation = XCTNSPredicateExpectation(predicate: synchronized, object: status)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func forceCloudSynchronization(
    in app: XCUIApplication,
    timeout: TimeInterval
  ) -> Bool {
    app.tabBars.buttons["设置"].tap()
    let refresh = app.buttons["manualCloudSyncButton"]
    for _ in 0..<5 where !refresh.isHittable { app.swipeUp() }
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

extension XCUIElement {
  func clearAndEnterText(_ text: String) {
    tap()
    if let current = value as? String, !current.isEmpty {
      typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    typeText(text)
  }
}
