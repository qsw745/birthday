# iOS Local Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建无需服务器即可完整使用的 iOS 17+ SwiftUI 生日本地应用，包括 SwiftData、农历换算、本地通知、Face ID 和已确认的三类主要页面。

**Architecture:** `BirthdayCore` Swift Package 承载领域模型、SwiftData、本地通知规划和安全抽象；XcodeGen 生成 `BirthdayMobile` SwiftUI 应用工程。所有用户写操作先进入本地数据库并原子追加 outbox，网络同步留给后续计划接入。

**Tech Stack:** Swift 6.3、SwiftUI、SwiftData、Foundation `Calendar(identifier: .chinese)`、UserNotifications、LocalAuthentication、Security、XcodeGen、Swift Testing/XCTest

**Spec:** `docs/superpowers/specs/2026-08-21-ios-local-first-birthday-app-design.md`

## Global Constraints

- 最低系统版本固定为 iOS 17.0；核心包同时支持 macOS 14.0 以便执行 `swift test`。
- App Bundle ID 使用 `top.qisw.birthday`；首版 `MARKETING_VERSION=1.0.0`、`CURRENT_PROJECT_VERSION=1`。
- 不增加第三方运行时依赖；XcodeGen 只作为开发期工程生成工具。
- 执行前使用 `superpowers:using-git-worktrees` 从当前 `main` 创建隔离工作树，避免触碰主工作区的未提交修改。
- 面向用户的文案全部使用简体中文。
- 本计划不得访问服务器；飞行模式是完整功能路径，不是降级缓存路径。
- 农历闰月规则固定为：目标年存在对应闰月时用闰月，否则使用同月普通月份。
- 本地提醒固定支持“提前一天”和“当天”两个开关，最多安排最近 60 条业务通知加 1 条维护提醒。
- 保留现有未提交的 `.DS_Store`、`package.json`、`package-lock.json` 和 `routes/auth.js` 修改，不得暂存或覆盖。
- 每项任务只提交其列出的文件；不得提交 `.superpowers/` 草图目录。

---

## File Structure

### 工程与应用

- `ios/project.yml`：XcodeGen 工程定义、Bundle ID、版本和本地 Swift Package 依赖。
- `ios/BirthdayMobile/App/BirthdayMobileApp.swift`：应用入口、依赖组装和 scene 生命周期。
- `ios/BirthdayMobile/App/AppModel.swift`：应用锁、首次启动、选中标签和全局健康状态。
- `ios/BirthdayMobile/Design/ModernAirTheme.swift`：现代空气感颜色、圆角、间距和材质。
- `ios/BirthdayMobile/Features/Calendar/CalendarHomeView.swift`：月历首页和所选日期列表。
- `ios/BirthdayMobile/Features/Birthdays/BirthdayListView.swift`：全部生日和搜索。
- `ios/BirthdayMobile/Features/Birthdays/BirthdayEditorView.swift`：原生分组新增/编辑表单。
- `ios/BirthdayMobile/Features/Settings/SettingsView.swift`：Face ID、通知和本地状态。
- `ios/BirthdayMobile/Features/Onboarding/OnboardingView.swift`：离线能力和通知用途说明。
- `ios/BirthdayMobile/Features/Lock/AppLockView.swift`：Face ID 锁定界面。
- `ios/BirthdayMobile/Info.plist`：Face ID 文案和后台任务标识。
- `ios/BirthdayMobile/Assets.xcassets`：应用颜色和图标占位资源。

### 可测试核心包

- `ios/BirthdayCore/Package.swift`：核心库与测试目标。
- `ios/BirthdayCore/Sources/BirthdayCore/Domain/BirthdayModels.swift`：领域值对象和记录。
- `ios/BirthdayCore/Sources/BirthdayCore/Domain/BirthdayValidator.swift`：输入验证。
- `ios/BirthdayCore/Sources/BirthdayCore/Domain/LunarBirthdayCalculator.swift`：农历到下一次公历日期。
- `ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayEntity.swift`：SwiftData 持久化模型。
- `ios/BirthdayCore/Sources/BirthdayCore/Data/SyncOperationEntity.swift`：本地待同步操作。
- `ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayStore.swift`：事务、查询、软删除和映射。
- `ios/BirthdayCore/Sources/BirthdayCore/Notifications/ReminderPlanner.swift`：纯函数通知候选规划。
- `ios/BirthdayCore/Sources/BirthdayCore/Notifications/UserNotificationScheduler.swift`：系统通知适配器。
- `ios/BirthdayCore/Sources/BirthdayCore/Security/AppLockService.swift`：Face ID 抽象和实现。
- `ios/BirthdayCore/Sources/BirthdayCore/Security/KeychainStore.swift`：钥匙串读写。
- `ios/BirthdayCore/Tests/BirthdayCoreTests/*Tests.swift`：领域、持久化、通知和安全测试。

---

### Task 1: Bootstrap the Swift Package and XcodeGen App

**Files:**
- Create: `ios/BirthdayCore/Package.swift`
- Create: `ios/BirthdayCore/Sources/BirthdayCore/BirthdayCore.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/BirthdayCoreSmokeTests.swift`
- Create: `ios/project.yml`
- Create: `ios/BirthdayMobile/App/BirthdayMobileApp.swift`
- Create: `ios/BirthdayMobile/Info.plist`
- Create: `ios/BirthdayMobile/Assets.xcassets/Contents.json`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: none
- Produces: Swift package product `BirthdayCore`; iOS app target `BirthdayMobile`; `BirthdayCore.version == 1`

- [ ] **Step 1: Write the failing package smoke test**

```swift
import Testing
@testable import BirthdayCore

@Test func exposesCoreVersion() {
    #expect(BirthdayCore.version == 1)
}
```

- [ ] **Step 2: Create the package manifest without the implementation and verify failure**

```swift
// ios/BirthdayCore/Package.swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BirthdayCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "BirthdayCore", targets: ["BirthdayCore"])],
    targets: [
        .target(name: "BirthdayCore"),
        .testTarget(name: "BirthdayCoreTests", dependencies: ["BirthdayCore"]),
    ]
)
```

Run: `cd ios/BirthdayCore && swift test`

Expected: FAIL because `BirthdayCore.version` does not exist.

- [ ] **Step 3: Add the minimal package implementation**

```swift
public enum BirthdayCore {
    public static let version = 1
}
```

- [ ] **Step 4: Add the XcodeGen project definition and app entry**

```yaml
# ios/project.yml
name: BirthdayMobile
options:
  deploymentTarget:
    iOS: "17.0"
packages:
  BirthdayCore:
    path: BirthdayCore
settings:
  base:
    PRODUCT_BUNDLE_IDENTIFIER: top.qisw.birthday
    MARKETING_VERSION: 1.0.0
    CURRENT_PROJECT_VERSION: 1
    SWIFT_VERSION: 6.0
    SWIFT_STRICT_CONCURRENCY: complete
targets:
  BirthdayMobile:
    type: application
    platform: iOS
    sources:
      - BirthdayMobile
    info:
      path: BirthdayMobile/Info.plist
      properties:
        CFBundleDisplayName: 岁时
        UILaunchScreen: {}
        NSFaceIDUsageDescription: 使用 Face ID 保护生日资料
        BGTaskSchedulerPermittedIdentifiers:
          - top.qisw.birthday.refresh
    dependencies:
      - package: BirthdayCore
```

```swift
import SwiftUI
import BirthdayCore

@main
struct BirthdayMobileApp: App {
    var body: some Scene {
        WindowGroup {
            Text("岁时")
        }
    }
}
```

- [ ] **Step 5: Ignore generated and visual-companion artifacts**

Append these exact lines to `.gitignore`:

```gitignore
.superpowers/
ios/BirthdayMobile.xcodeproj/
ios/.build/
ios/DerivedData/
```

- [ ] **Step 6: Generate and verify both deliverables**

Run: `cd ios/BirthdayCore && swift test`

Expected: PASS with 1 test.

Run: `cd ios && xcodegen generate`

Expected: `BirthdayMobile.xcodeproj` is generated successfully.

Run: `xcodebuild -project ios/BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add .gitignore ios/project.yml ios/BirthdayCore ios/BirthdayMobile
git commit -m "feat(ios): 初始化本地生日应用工程"
```

---

### Task 2: Define Domain Models and Validation

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Domain/BirthdayModels.swift`
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Domain/BirthdayValidator.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/BirthdayValidatorTests.swift`

**Interfaces:**
- Consumes: `Foundation.UUID`, `Foundation.Date`
- Produces: `LunarBirthday`, `ReminderConfig`, `BirthdayDraft`, `BirthdayRecord`, `SyncState`, `BirthdayValidator.validate(_:)`

- [ ] **Step 1: Write failing validation tests**

```swift
import Foundation
import Testing
@testable import BirthdayCore

private actor FakeNotificationCenterClient: NotificationCenterClient {
    let configuredAuthorization: NotificationAuthorization
    let configuredPending: [String]
    private(set) var removed: [String] = []
    private(set) var added: [ReminderCandidate] = []

    init(authorization: NotificationAuthorization, pendingIdentifiers: [String]) {
        self.configuredAuthorization = authorization
        self.configuredPending = pendingIdentifiers
    }
    func authorization() async -> NotificationAuthorization { configuredAuthorization }
    func pendingIdentifiers() async -> [String] { configuredPending }
    func remove(identifiers: [String]) async { removed = identifiers }
    func add(_ candidate: ReminderCandidate) async throws { added.append(candidate) }
    func capturedRemoved() -> [String] { removed }
    func capturedAdded() -> [ReminderCandidate] { added }
}

private func makeReminderPlan(count: Int) -> ReminderPlan {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let items = (0..<count).map { index in
        ReminderCandidate(identifier: "birthday.\(index)", birthdayId: UUID(), kind: .sameDay, triggerDate: start.addingTimeInterval(Double(index * 60)), title: "生日提醒", body: "记得送上祝福。")
    }
    let maintenance = ReminderCandidate(identifier: "birthday.maintenance", birthdayId: nil, kind: .maintenance, triggerDate: start.addingTimeInterval(86_400), title: "请更新生日提醒", body: "打开岁时继续安排。")
    return ReminderPlan(birthdayNotifications: items, maintenanceNotification: maintenance, coverageEnd: items.last?.triggerDate)
}

@Test func rejectsEmptyName() {
    let draft = BirthdayDraft(
        name: "  ",
        lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false),
        reminder: .defaults
    )
    #expect(throws: BirthdayValidationError.emptyName) {
        try BirthdayValidator.validate(draft)
    }
}

@Test func rejectsInvalidLunarDay() {
    let draft = BirthdayDraft(
        name: "妈妈",
        lunarBirthday: .init(month: 8, day: 31, isLeapMonth: false),
        reminder: .defaults
    )
    #expect(throws: BirthdayValidationError.invalidLunarDay) {
        try BirthdayValidator.validate(draft)
    }
}

@Test func requiresEmailWhenEmailReminderIsEnabled() {
    let reminder = ReminderConfig(
        timeMinutes: 540,
        notifyDayBefore: true,
        notifySameDay: true,
        emailEnabled: true,
        emailAddress: "",
        emailMessage: "生日快乐"
    )
    let draft = BirthdayDraft(name: "妈妈", lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false), reminder: reminder)
    #expect(throws: BirthdayValidationError.invalidEmail) {
        try BirthdayValidator.validate(draft)
    }
}
```

- [ ] **Step 2: Run tests and verify model symbols are missing**

Run: `cd ios/BirthdayCore && swift test --filter BirthdayValidatorTests`

Expected: compile failure for missing `BirthdayDraft` and related symbols.

- [ ] **Step 3: Implement exact domain types**

```swift
import Foundation

public struct LunarBirthday: Codable, Equatable, Hashable, Sendable {
    public var month: Int
    public var day: Int
    public var isLeapMonth: Bool
    public init(month: Int, day: Int, isLeapMonth: Bool) {
        self.month = month
        self.day = day
        self.isLeapMonth = isLeapMonth
    }
}

public struct ReminderConfig: Codable, Equatable, Sendable {
    public var timeMinutes: Int
    public var notifyDayBefore: Bool
    public var notifySameDay: Bool
    public var emailEnabled: Bool
    public var emailAddress: String
    public var emailMessage: String
    public static let defaults = ReminderConfig(
        timeMinutes: 540,
        notifyDayBefore: true,
        notifySameDay: true,
        emailEnabled: false,
        emailAddress: "",
        emailMessage: "生日快乐"
    )
}

public struct BirthdayDraft: Equatable, Sendable {
    public var name: String
    public var lunarBirthday: LunarBirthday
    public var reminder: ReminderConfig
}

public enum SyncState: String, Codable, Sendable {
    case synced, pending, conflict, pendingDelete
}

public struct BirthdayRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var lunarBirthday: LunarBirthday
    public var reminder: ReminderConfig
    public var nextSolarDate: Date?
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var syncState: SyncState
}

public struct SyncOperation: Identifiable, Equatable, Sendable {
    public var id: UUID { operationId }
    public let operationId: UUID
    public let entityId: UUID
    public let operationType: String
    public let baseVersion: Int64
    public let payloadJSON: Data
    public let createdAt: Date
    public let attemptCount: Int
    public let nextRetryAt: Date?
    public let lastErrorCategory: String?
}
```

- [ ] **Step 4: Implement validation with stable errors**

```swift
import Foundation

public enum BirthdayValidationError: Error, Equatable {
    case emptyName, nameTooLong, invalidLunarMonth, invalidLunarDay, invalidReminderTime, noNotificationSelected, invalidEmail
}

public enum BirthdayValidator {
    public static func validate(_ draft: BirthdayDraft) throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BirthdayValidationError.emptyName }
        guard name.count <= 64 else { throw BirthdayValidationError.nameTooLong }
        guard (1...12).contains(draft.lunarBirthday.month) else { throw BirthdayValidationError.invalidLunarMonth }
        guard (1...30).contains(draft.lunarBirthday.day) else { throw BirthdayValidationError.invalidLunarDay }
        guard (0..<1_440).contains(draft.reminder.timeMinutes) else { throw BirthdayValidationError.invalidReminderTime }
        guard draft.reminder.notifyDayBefore || draft.reminder.notifySameDay else { throw BirthdayValidationError.noNotificationSelected }
        if draft.reminder.emailEnabled {
            let email = draft.reminder.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard email.contains("@"), email.count <= 128 else { throw BirthdayValidationError.invalidEmail }
        }
    }
}
```

- [ ] **Step 5: Run all core tests**

Run: `cd ios/BirthdayCore && swift test`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Domain ios/BirthdayCore/Tests/BirthdayCoreTests/BirthdayValidatorTests.swift
git commit -m "feat(ios): 定义生日领域模型与校验"
```

---

### Task 3: Implement Chinese Lunar Date Calculation

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Domain/LunarBirthdayCalculator.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/LunarBirthdayCalculatorTests.swift`

**Interfaces:**
- Consumes: `LunarBirthday`
- Produces: `LunarBirthdayCalculating.nextOccurrence(of:reminderMinutes:after:in:) -> Date`

- [ ] **Step 1: Write failing ordinary, leap-present, leap-missing, and rollover tests**

```swift
import Foundation
import Testing
@testable import BirthdayCore

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
private let iso = ISO8601DateFormatter()

@Test func maps2026LunarNewYear() throws {
    let result = try ChineseCalendarBirthdayCalculator().nextOccurrence(
        of: .init(month: 1, day: 1, isLeapMonth: false),
        reminderMinutes: 540,
        after: iso.date(from: "2026-01-01T00:00:00Z")!,
        in: shanghai
    )
    let components = Calendar(identifier: .gregorian).dateComponents(in: shanghai, from: result)
    #expect(components.year == 2026 && components.month == 2 && components.day == 17 && components.hour == 9)
}

@Test func usesLeapSixthMonthWhenPresent() throws {
    let result = try ChineseCalendarBirthdayCalculator().nextOccurrence(
        of: .init(month: 6, day: 1, isLeapMonth: true),
        reminderMinutes: 540,
        after: iso.date(from: "2025-01-01T00:00:00Z")!,
        in: shanghai
    )
    let components = Calendar(identifier: .gregorian).dateComponents(in: shanghai, from: result)
    #expect(components.year == 2025 && components.month == 7 && components.day == 25)
}

@Test func fallsBackToOrdinaryMonthWhenLeapMonthIsMissing() throws {
    let result = try ChineseCalendarBirthdayCalculator().nextOccurrence(
        of: .init(month: 6, day: 1, isLeapMonth: true),
        reminderMinutes: 540,
        after: iso.date(from: "2026-01-01T00:00:00Z")!,
        in: shanghai
    )
    let lunar = Calendar(identifier: .chinese).dateComponents(in: shanghai, from: result)
    #expect(lunar.month == 6 && lunar.day == 1 && lunar.isLeapMonth == false)
}

@Test func rollsPastOccurrenceIntoNextYear() throws {
    let result = try ChineseCalendarBirthdayCalculator().nextOccurrence(
        of: .init(month: 8, day: 15, isLeapMonth: false),
        reminderMinutes: 540,
        after: iso.date(from: "2026-09-25T02:00:00Z")!,
        in: shanghai
    )
    #expect(result > iso.date(from: "2027-01-01T00:00:00Z")!)
}
```

- [ ] **Step 2: Run and verify failure**

Run: `cd ios/BirthdayCore && swift test --filter LunarBirthdayCalculatorTests`

Expected: compile failure for missing calculator.

- [ ] **Step 3: Implement day scanning with explicit leap fallback**

```swift
import Foundation

public protocol LunarBirthdayCalculating: Sendable {
    func nextOccurrence(of birthday: LunarBirthday, reminderMinutes: Int, after now: Date, in timeZone: TimeZone) throws -> Date
}

public enum LunarBirthdayCalculationError: Error, Equatable {
    case occurrenceNotFound
}

public struct ChineseCalendarBirthdayCalculator: LunarBirthdayCalculating {
    public init() {}

    public func nextOccurrence(of birthday: LunarBirthday, reminderMinutes: Int, after now: Date, in timeZone: TimeZone) throws -> Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = timeZone
        let start = gregorian.startOfDay(for: now)

        if !birthday.isLeapMonth {
            for offset in 0..<800 {
                guard let day = gregorian.date(byAdding: .day, value: offset, to: start) else { continue }
                let lunar = chinese.dateComponents([.month, .day, .isLeapMonth], from: day)
                guard lunar.month == birthday.month, lunar.day == birthday.day, lunar.isLeapMonth == false else { continue }
                if let candidate = wallTime(on: day, minutes: reminderMinutes, calendar: gregorian), candidate > now { return candidate }
            }
            throw LunarBirthdayCalculationError.occurrenceNotFound
        }

        var activeLunarYear: String?
        var ordinaryCandidate: Date?
        var leapCandidate: Date?
        for offset in 0..<800 {
            guard let day = gregorian.date(byAdding: .day, value: offset, to: start) else { continue }
            let lunar = chinese.dateComponents([.era, .year, .month, .day, .isLeapMonth], from: day)
            let lunarYear = "\(lunar.era ?? 0):\(lunar.year ?? 0)"
            if let activeLunarYear, activeLunarYear != lunarYear {
                if let selected = leapCandidate ?? ordinaryCandidate { return selected }
                ordinaryCandidate = nil
                leapCandidate = nil
            }
            activeLunarYear = lunarYear
            guard lunar.month == birthday.month, lunar.day == birthday.day,
                  let candidate = wallTime(on: day, minutes: reminderMinutes, calendar: gregorian), candidate > now else { continue }
            if lunar.isLeapMonth == true { leapCandidate = candidate } else { ordinaryCandidate = candidate }
        }
        if let selected = leapCandidate ?? ordinaryCandidate { return selected }
        throw LunarBirthdayCalculationError.occurrenceNotFound
    }

    private func wallTime(on day: Date, minutes: Int, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = minutes / 60
        components.minute = minutes % 60
        components.second = 0
        return calendar.date(from: components)
    }
}
```

- [ ] **Step 4: Run targeted and full tests**

Run: `cd ios/BirthdayCore && swift test --filter LunarBirthdayCalculatorTests`

Expected: 4 tests PASS.

Run: `cd ios/BirthdayCore && swift test`

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Domain/LunarBirthdayCalculator.swift ios/BirthdayCore/Tests/BirthdayCoreTests/LunarBirthdayCalculatorTests.swift
git commit -m "feat(ios): 实现农历生日换算"
```

---

### Task 4: Add SwiftData Persistence and Transactional Outbox

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayEntity.swift`
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Data/SyncOperationEntity.swift`
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayStore.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/BirthdayStoreTests.swift`

**Interfaces:**
- Consumes: `BirthdayDraft`, `BirthdayRecord`, `BirthdayValidator`, `LunarBirthdayCalculating`
- Produces: `BirthdayStore.save(_:id:now:timeZone:)`, `activeBirthdays()`, `softDelete(id:now:)`, `restore(id:now:)`, `pendingOperations()`

- [ ] **Step 1: Write failing in-memory persistence tests**

```swift
import Foundation
import SwiftData
import Testing
@testable import BirthdayCore

@Test func savePersistsBirthdayAndOutboxAtomically() async throws {
    let container = try ModelContainer(
        for: BirthdayEntity.self, SyncOperationEntity.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let store = BirthdayStore(modelContainer: container)
    let draft = BirthdayDraft(name: "妈妈", lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false), reminder: .defaults)
    let saved = try await store.save(draft, id: nil, now: Date(timeIntervalSince1970: 1_788_000_000), timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    #expect(await store.activeBirthdays().map(\.id) == [saved.id])
    #expect(await store.pendingOperations().count == 1)
}

@Test func softDeleteHidesRecordAndCreatesDeleteOperation() async throws {
    let container = try ModelContainer(
        for: BirthdayEntity.self, SyncOperationEntity.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let store = BirthdayStore(modelContainer: container)
    let saved = try await store.save(.init(name: "爸爸", lunarBirthday: .init(month: 9, day: 3, isLeapMonth: false), reminder: .defaults), id: nil, now: .now, timeZone: .current)
    try await store.softDelete(id: saved.id, now: .now)
    #expect(await store.activeBirthdays().isEmpty)
    #expect(await store.pendingOperations().last?.operationType == "delete")
}
```

- [ ] **Step 2: Run and verify missing persistence types**

Run: `cd ios/BirthdayCore && swift test --filter BirthdayStoreTests`

Expected: compile failure for missing entities and store.

- [ ] **Step 3: Implement the two SwiftData entities**

```swift
import Foundation
import SwiftData

@Model
public final class BirthdayEntity {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var lunarMonth: Int
    public var lunarDay: Int
    public var isLeapMonth: Bool
    public var reminderTimeMinutes: Int
    public var notifyDayBefore: Bool
    public var notifySameDay: Bool
    public var emailEnabled: Bool
    public var emailAddress: String
    public var emailMessage: String
    public var nextSolarDate: Date?
    public var version: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var syncStateRaw: String

    public init(id: UUID, draft: BirthdayDraft, nextSolarDate: Date, now: Date) {
        self.id = id
        self.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.lunarMonth = draft.lunarBirthday.month
        self.lunarDay = draft.lunarBirthday.day
        self.isLeapMonth = draft.lunarBirthday.isLeapMonth
        self.reminderTimeMinutes = draft.reminder.timeMinutes
        self.notifyDayBefore = draft.reminder.notifyDayBefore
        self.notifySameDay = draft.reminder.notifySameDay
        self.emailEnabled = draft.reminder.emailEnabled
        self.emailAddress = draft.reminder.emailAddress
        self.emailMessage = draft.reminder.emailMessage
        self.nextSolarDate = nextSolarDate
        self.version = 0
        self.createdAt = now
        self.updatedAt = now
        self.deletedAt = nil
        self.syncStateRaw = SyncState.pending.rawValue
    }
}

@Model
public final class SyncOperationEntity {
    @Attribute(.unique) public var operationId: UUID
    public var entityId: UUID
    public var operationType: String
    public var baseVersion: Int64
    public var payloadJSON: Data
    public var createdAt: Date
    public var attemptCount: Int
    public var nextRetryAt: Date?
    public var lastErrorCategory: String?

    public init(operationId: UUID, entityId: UUID, operationType: String, baseVersion: Int64, payloadJSON: Data, createdAt: Date, attemptCount: Int, nextRetryAt: Date?, lastErrorCategory: String?) {
        self.operationId = operationId
        self.entityId = entityId
        self.operationType = operationType
        self.baseVersion = baseVersion
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.lastErrorCategory = lastErrorCategory
    }
}
```

- [ ] **Step 4: Implement the model actor and atomic save/delete paths**

```swift
import Foundation
import SwiftData

@ModelActor
public actor BirthdayStore {
    private let calculator: any LunarBirthdayCalculating = ChineseCalendarBirthdayCalculator()

    public func save(_ draft: BirthdayDraft, id: UUID?, now: Date, timeZone: TimeZone) throws -> BirthdayRecord {
        try BirthdayValidator.validate(draft)
        let next = try calculator.nextOccurrence(of: draft.lunarBirthday, reminderMinutes: draft.reminder.timeMinutes, after: now, in: timeZone)
        let targetId = id ?? UUID()
        let descriptor = FetchDescriptor<BirthdayEntity>(predicate: #Predicate { $0.id == targetId })
        let entity = try modelContext.fetch(descriptor).first ?? BirthdayEntity(id: targetId, draft: draft, nextSolarDate: next, now: now)
        if entity.modelContext == nil { modelContext.insert(entity) }
        apply(draft, nextSolarDate: next, now: now, to: entity)
        let payload = try JSONEncoder().encode(map(entity))
        modelContext.insert(SyncOperationEntity(operationId: UUID(), entityId: targetId, operationType: "upsert", baseVersion: entity.version, payloadJSON: payload, createdAt: now, attemptCount: 0, nextRetryAt: nil, lastErrorCategory: nil))
        try modelContext.save()
        return map(entity)
    }

    public func activeBirthdays() -> [BirthdayRecord] {
        let descriptor = FetchDescriptor<BirthdayEntity>(predicate: #Predicate { $0.deletedAt == nil }, sortBy: [SortDescriptor(\.nextSolarDate)])
        return (try? modelContext.fetch(descriptor).map(map)) ?? []
    }

    public func softDelete(id: UUID, now: Date) throws {
        let descriptor = FetchDescriptor<BirthdayEntity>(predicate: #Predicate { $0.id == id })
        guard let entity = try modelContext.fetch(descriptor).first else { return }
        entity.deletedAt = now
        entity.updatedAt = now
        entity.syncStateRaw = SyncState.pendingDelete.rawValue
        let payload = try JSONEncoder().encode(map(entity))
        modelContext.insert(SyncOperationEntity(operationId: UUID(), entityId: id, operationType: "delete", baseVersion: entity.version, payloadJSON: payload, createdAt: now, attemptCount: 0, nextRetryAt: nil, lastErrorCategory: nil))
        try modelContext.save()
    }

    public func restore(id: UUID, now: Date) throws {
        let descriptor = FetchDescriptor<BirthdayEntity>(predicate: #Predicate { $0.id == id })
        guard let entity = try modelContext.fetch(descriptor).first else { return }
        entity.deletedAt = nil
        entity.updatedAt = now
        entity.syncStateRaw = SyncState.pending.rawValue
        let payload = try JSONEncoder().encode(map(entity))
        modelContext.insert(SyncOperationEntity(operationId: UUID(), entityId: id, operationType: "upsert", baseVersion: entity.version, payloadJSON: payload, createdAt: now, attemptCount: 0, nextRetryAt: nil, lastErrorCategory: nil))
        try modelContext.save()
    }

    public func pendingOperations() -> [SyncOperation] {
        let descriptor = FetchDescriptor<SyncOperationEntity>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? modelContext.fetch(descriptor).map { entity in
            SyncOperation(operationId: entity.operationId, entityId: entity.entityId, operationType: entity.operationType, baseVersion: entity.baseVersion, payloadJSON: entity.payloadJSON, createdAt: entity.createdAt, attemptCount: entity.attemptCount, nextRetryAt: entity.nextRetryAt, lastErrorCategory: entity.lastErrorCategory)
        }) ?? []
    }

    private func apply(_ draft: BirthdayDraft, nextSolarDate: Date, now: Date, to entity: BirthdayEntity) {
        entity.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        entity.lunarMonth = draft.lunarBirthday.month
        entity.lunarDay = draft.lunarBirthday.day
        entity.isLeapMonth = draft.lunarBirthday.isLeapMonth
        entity.reminderTimeMinutes = draft.reminder.timeMinutes
        entity.notifyDayBefore = draft.reminder.notifyDayBefore
        entity.notifySameDay = draft.reminder.notifySameDay
        entity.emailEnabled = draft.reminder.emailEnabled
        entity.emailAddress = draft.reminder.emailAddress
        entity.emailMessage = draft.reminder.emailMessage
        entity.nextSolarDate = nextSolarDate
        entity.updatedAt = now
        entity.deletedAt = nil
        entity.syncStateRaw = SyncState.pending.rawValue
    }

    private func map(_ entity: BirthdayEntity) -> BirthdayRecord {
        BirthdayRecord(
            id: entity.id,
            name: entity.name,
            lunarBirthday: LunarBirthday(month: entity.lunarMonth, day: entity.lunarDay, isLeapMonth: entity.isLeapMonth),
            reminder: ReminderConfig(timeMinutes: entity.reminderTimeMinutes, notifyDayBefore: entity.notifyDayBefore, notifySameDay: entity.notifySameDay, emailEnabled: entity.emailEnabled, emailAddress: entity.emailAddress, emailMessage: entity.emailMessage),
            nextSolarDate: entity.nextSolarDate,
            version: entity.version,
            createdAt: entity.createdAt,
            updatedAt: entity.updatedAt,
            deletedAt: entity.deletedAt,
            syncState: SyncState(rawValue: entity.syncStateRaw) ?? .pending
        )
    }
}
```

Extend `BirthdayStoreTests` with these exact assertions:

```swift
@Test func reminderFieldsAndVersionRoundTrip() async throws {
    let store = BirthdayStore(modelContainer: try ModelContainer(for: BirthdayEntity.self, SyncOperationEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    let reminder = ReminderConfig(timeMinutes: 615, notifyDayBefore: false, notifySameDay: true, emailEnabled: true, emailAddress: "a@example.com", emailMessage: "记得打电话")
    let saved = try await store.save(.init(name: "妈妈", lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false), reminder: reminder), id: nil, now: .now, timeZone: .current)
    #expect(saved.reminder == reminder)
    #expect(saved.version == 0)
}

@Test func restoreMakesRecordActiveAndQueuesUpsert() async throws {
    let store = BirthdayStore(modelContainer: try ModelContainer(for: BirthdayEntity.self, SyncOperationEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    let saved = try await store.save(.init(name: "爸爸", lunarBirthday: .init(month: 9, day: 3, isLeapMonth: false), reminder: .defaults), id: nil, now: .now, timeZone: .current)
    try await store.softDelete(id: saved.id, now: .now)
    try await store.restore(id: saved.id, now: .now)
    #expect(await store.activeBirthdays().map(\.id) == [saved.id])
    #expect(await store.pendingOperations().last?.operationType == "upsert")
}
```

- [ ] **Step 5: Run persistence tests and full package tests**

Run: `cd ios/BirthdayCore && swift test --filter BirthdayStoreTests`

Expected: persistence tests PASS.

Run: `cd ios/BirthdayCore && swift test`

Expected: all tests PASS under Swift strict concurrency.

- [ ] **Step 6: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Data ios/BirthdayCore/Tests/BirthdayCoreTests/BirthdayStoreTests.swift
git commit -m "feat(ios): 增加本地数据库与待同步队列"
```

---

### Task 5: Build the 60-Slot Reminder Planner

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Notifications/ReminderPlanner.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/ReminderPlannerTests.swift`

**Interfaces:**
- Consumes: `[BirthdayRecord]`, `LunarBirthdayCalculating`
- Produces: `ReminderPlanner.makePlan(records:now:timeZone:) -> ReminderPlan`

- [ ] **Step 1: Write failing planner tests**

```swift
import Foundation
import Testing
@testable import BirthdayCore

@Test func capsBirthdayNotificationsAtSixtyAndAddsMaintenance() throws {
    let records = (0..<100).map { index in
        BirthdayRecord.fixture(id: UUID(), name: "联系人\(index)", month: index % 12 + 1, day: index % 28 + 1)
    }
    let plan = try ReminderPlanner().makePlan(records: records, now: Date(timeIntervalSince1970: 1_788_000_000), timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    #expect(plan.birthdayNotifications.count == 60)
    #expect(plan.maintenanceNotification != nil)
    #expect(plan.coverageEnd == plan.birthdayNotifications.last?.triggerDate)
}

@Test func emitsDayBeforeAndSameDayIdentifiers() throws {
    let record = BirthdayRecord.fixture(id: UUID(), name: "妈妈", month: 8, day: 15)
    let plan = try ReminderPlanner().makePlan(records: [record], now: Date(timeIntervalSince1970: 1_788_000_000), timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    #expect(plan.birthdayNotifications.map(\.kind) == [.dayBefore, .sameDay])
    #expect(Set(plan.birthdayNotifications.map(\.identifier)).count == 2)
}
```

- [ ] **Step 2: Run and verify missing planner types**

Run: `cd ios/BirthdayCore && swift test --filter ReminderPlannerTests`

Expected: compile failure for missing planner.

- [ ] **Step 3: Implement candidate generation, ordering, cap, and maintenance**

```swift
import Foundation

public enum ReminderKind: String, Codable, Sendable { case dayBefore, sameDay, maintenance }

public struct ReminderCandidate: Equatable, Sendable {
    public let identifier: String
    public let birthdayId: UUID?
    public let kind: ReminderKind
    public let triggerDate: Date
    public let title: String
    public let body: String
}

public struct ReminderPlan: Equatable, Sendable {
    public let birthdayNotifications: [ReminderCandidate]
    public let maintenanceNotification: ReminderCandidate?
    public let coverageEnd: Date?
}

public struct ReminderPlanner: Sendable {
    private let calculator: any LunarBirthdayCalculating
    public init(calculator: any LunarBirthdayCalculating = ChineseCalendarBirthdayCalculator()) {
        self.calculator = calculator
    }

    public func makePlan(records: [BirthdayRecord], now: Date, timeZone: TimeZone) throws -> ReminderPlan {
        var candidates: [ReminderCandidate] = []
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        for record in records where record.deletedAt == nil {
            let occurrence = try calculator.nextOccurrence(of: record.lunarBirthday, reminderMinutes: record.reminder.timeMinutes, after: now, in: timeZone)
            if record.reminder.notifyDayBefore {
                let trigger = calendar.date(byAdding: .day, value: -1, to: occurrence)!
                if trigger > now { candidates.append(candidate(for: record, kind: .dayBefore, trigger: trigger)) }
            }
            if record.reminder.notifySameDay, occurrence > now {
                candidates.append(candidate(for: record, kind: .sameDay, trigger: occurrence))
            }
        }
        let selected = Array(candidates.sorted { $0.triggerDate < $1.triggerDate }.prefix(60))
        let coverageEnd = selected.last?.triggerDate
        let maintenance = coverageEnd.flatMap { end -> ReminderCandidate? in
            guard let trigger = calendar.date(byAdding: .day, value: -30, to: end), trigger > now else { return nil }
            return ReminderCandidate(identifier: "birthday.maintenance.\(Int(end.timeIntervalSince1970))", birthdayId: nil, kind: .maintenance, triggerDate: trigger, title: "请更新生日提醒", body: "打开岁时，继续安排后续本地提醒。")
        }
        return ReminderPlan(birthdayNotifications: selected, maintenanceNotification: maintenance, coverageEnd: coverageEnd)
    }

    private func candidate(for record: BirthdayRecord, kind: ReminderKind, trigger: Date) -> ReminderCandidate {
        let suffix = String(Int(trigger.timeIntervalSince1970))
        let title = kind == .dayBefore ? "明天是\(record.name)的生日" : "今天是\(record.name)的生日"
        let body = kind == .dayBefore ? "提前准备一份心意吧。" : "别忘了送上生日祝福。"
        return ReminderCandidate(identifier: "birthday.\(record.id.uuidString).\(kind.rawValue).\(suffix)", birthdayId: record.id, kind: kind, triggerDate: trigger, title: title, body: body)
    }
}
```

Add this complete shared test fixture in `Tests/BirthdayCoreTests/Fixtures.swift`:

```swift
import Foundation
@testable import BirthdayCore

extension BirthdayRecord {
    static func fixture(id: UUID, name: String, month: Int, day: Int, nextSolarDate: Date? = nil) -> BirthdayRecord {
        BirthdayRecord(
            id: id,
            name: name,
            lunarBirthday: LunarBirthday(month: month, day: day, isLeapMonth: false),
            reminder: .defaults,
            nextSolarDate: nextSolarDate,
            version: 0,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deletedAt: nil,
            syncState: .pending
        )
    }
}
```

- [ ] **Step 4: Run planner and full tests**

Run: `cd ios/BirthdayCore && swift test --filter ReminderPlannerTests`

Expected: planner tests PASS.

Run: `cd ios/BirthdayCore && swift test`

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Notifications/ReminderPlanner.swift ios/BirthdayCore/Tests/BirthdayCoreTests/ReminderPlannerTests.swift ios/BirthdayCore/Tests/BirthdayCoreTests/Fixtures.swift
git commit -m "feat(ios): 规划滚动本地提醒窗口"
```

---

### Task 6: Schedule Notifications and Expose Health

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Notifications/UserNotificationScheduler.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/UserNotificationSchedulerTests.swift`

**Interfaces:**
- Consumes: `ReminderPlan`
- Produces: `NotificationScheduling.apply(_:) -> NotificationHealth`, `NotificationHealth`

- [ ] **Step 1: Write failing tests with a fake notification center**

```swift
import Foundation
import Testing
@testable import BirthdayCore

@Test func removesOnlyBirthdayNamespaceAndAddsPlan() async throws {
    let center = FakeNotificationCenterClient(
        authorization: .authorized,
        pendingIdentifiers: ["other.app", "birthday.old"]
    )
    let scheduler = UserNotificationScheduler(center: center)
    let plan = makeReminderPlan(count: 2)
    let health = try await scheduler.apply(plan)
    #expect(await center.capturedRemoved() == ["birthday.old"])
    #expect(await center.capturedAdded().count == 3)
    #expect(health.state == .scheduled)
}

@Test func reportsDeniedWithoutPretendingToSchedule() async throws {
    let center = FakeNotificationCenterClient(authorization: .denied, pendingIdentifiers: [])
    let health = try await UserNotificationScheduler(center: center).apply(makeReminderPlan(count: 2))
    #expect(health.state == .permissionDenied)
    #expect(await center.capturedAdded().isEmpty)
}
```

- [ ] **Step 2: Run and verify missing scheduler types**

Run: `cd ios/BirthdayCore && swift test --filter UserNotificationSchedulerTests`

Expected: compile failure.

- [ ] **Step 3: Implement the client protocol, health model, and scheduler**

```swift
import Foundation
import UserNotifications

public enum NotificationAuthorization: Sendable { case notDetermined, authorized, denied, provisional }
public enum NotificationHealthState: Sendable { case scheduled, permissionDenied, notRequested, failed }

public struct NotificationHealth: Sendable {
    public let state: NotificationHealthState
    public let scheduledCount: Int
    public let coverageEnd: Date?
    public let errorCategory: String?
}

public protocol NotificationCenterClient: Sendable {
    func authorization() async -> NotificationAuthorization
    func pendingIdentifiers() async -> [String]
    func remove(identifiers: [String]) async
    func add(_ candidate: ReminderCandidate) async throws
}

public protocol NotificationScheduling: Sendable {
    func apply(_ plan: ReminderPlan) async throws -> NotificationHealth
}

public struct UserNotificationScheduler: NotificationScheduling {
    private let center: any NotificationCenterClient
    public init(center: any NotificationCenterClient) { self.center = center }

    public func apply(_ plan: ReminderPlan) async throws -> NotificationHealth {
        let authorization = await center.authorization()
        guard authorization == .authorized || authorization == .provisional else {
            return NotificationHealth(state: authorization == .denied ? .permissionDenied : .notRequested, scheduledCount: 0, coverageEnd: nil, errorCategory: nil)
        }
        let owned = await center.pendingIdentifiers().filter { $0.hasPrefix("birthday.") }
        await center.remove(identifiers: owned)
        let candidates = plan.birthdayNotifications + [plan.maintenanceNotification].compactMap { $0 }
        do {
            for candidate in candidates { try await center.add(candidate) }
            return NotificationHealth(state: .scheduled, scheduledCount: candidates.count, coverageEnd: plan.coverageEnd, errorCategory: nil)
        } catch {
            return NotificationHealth(state: .failed, scheduledCount: 0, coverageEnd: nil, errorCategory: "schedule_failed")
        }
    }
}
```

Implement `SystemNotificationCenterClient` in the same file using `UNUserNotificationCenter`, `UNCalendarNotificationTrigger`, and `UNNotificationRequest`. Convert the trigger date using `Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from:)` and do not create repeating requests.

- [ ] **Step 4: Run tests and generic iOS build**

Run: `cd ios/BirthdayCore && swift test --filter UserNotificationSchedulerTests`

Expected: tests PASS.

Run: `cd ios && xcodegen generate && xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: build succeeds with UserNotifications linked.

- [ ] **Step 5: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Notifications/UserNotificationScheduler.swift ios/BirthdayCore/Tests/BirthdayCoreTests/UserNotificationSchedulerTests.swift
git commit -m "feat(ios): 接入系统本地通知与健康状态"
```

---

### Task 7: Add Face ID and Keychain Services

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Security/AppLockService.swift`
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Security/KeychainStore.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/AppLockServiceTests.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/KeychainStoreTests.swift`

**Interfaces:**
- Consumes: LocalAuthentication and Security frameworks
- Produces: `AppLockAuthenticating.unlock(reason:)`, `SecureTokenStore.save/read/delete`

- [ ] **Step 1: Write failing app-lock and token-store contract tests**

```swift
import Foundation
import Testing
@testable import BirthdayCore

private struct FakeAppLockAuthenticator: AppLockAuthenticating {
    let result: Bool
    func unlock(reason: String) async throws -> Bool { result }
}

// Add this shared fake to Fixtures.swift after SecureTokenStore exists;
// the later sync plan reuses it without redeclaration.
final class InMemorySecureTokenStore: SecureTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func save(_ data: Data, account: String) throws { lock.withLock { values[account] = data } }
    func read(account: String) throws -> Data? { lock.withLock { values[account] } }
    func delete(account: String) throws { lock.withLock { values.removeValue(forKey: account) } }
    var accounts: [String] { lock.withLock { values.keys.sorted() } }
}

@Test func fakeAppLockReturnsConfiguredResult() async throws {
    let lock = FakeAppLockAuthenticator(result: true)
    #expect(try await lock.unlock(reason: "解锁生日资料"))
}

@Test func inMemoryTokenStoreRoundTripsData() throws {
    let store = InMemorySecureTokenStore()
    try store.save(Data("secret".utf8), account: "refresh-token")
    #expect(try store.read(account: "refresh-token") == Data("secret".utf8))
    try store.delete(account: "refresh-token")
    #expect(try store.read(account: "refresh-token") == nil)
}
```

- [ ] **Step 2: Run and verify missing protocols**

Run: `cd ios/BirthdayCore && swift test --filter AppLockServiceTests && swift test --filter KeychainStoreTests`

Expected: compile failure.

- [ ] **Step 3: Implement protocol and LocalAuthentication adapter**

```swift
import LocalAuthentication

public protocol AppLockAuthenticating: Sendable {
    func unlock(reason: String) async throws -> Bool
}

public struct LocalAuthenticationService: AppLockAuthenticating {
    public init() {}
    public func unlock(reason: String) async throws -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "使用设备密码"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}
```

- [ ] **Step 4: Implement Keychain with this-device-only accessibility**

```swift
import Foundation
import Security

public protocol SecureTokenStore: Sendable {
    func save(_ data: Data, account: String) throws
    func read(account: String) throws -> Data?
    func delete(account: String) throws
}

public struct KeychainStore: SecureTokenStore {
    private let service = "top.qisw.birthday"
    public init() {}
    public func save(_ data: Data, account: String) throws {
        try delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
    public func read(account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }
    public func delete(account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

public enum KeychainError: Error { case status(OSStatus) }
```

- [ ] **Step 5: Run tests and build**

Run: `cd ios/BirthdayCore && swift test`

Expected: all tests PASS; Keychain contract tests use `InMemorySecureTokenStore`, while a signed-device test is deferred to final acceptance.

Run: `cd ios && xcodegen generate && xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Security ios/BirthdayCore/Tests/BirthdayCoreTests/AppLockServiceTests.swift ios/BirthdayCore/Tests/BirthdayCoreTests/KeychainStoreTests.swift ios/BirthdayCore/Tests/BirthdayCoreTests/Fixtures.swift
git commit -m "feat(ios): 增加 Face ID 与钥匙串服务"
```

---

### Task 8: Build the Modern-Air App Shell and Calendar Home

**Files:**
- Create: `ios/BirthdayMobile/App/AppModel.swift`
- Create: `ios/BirthdayMobile/Design/ModernAirTheme.swift`
- Create: `ios/BirthdayMobile/Features/Calendar/CalendarHomeView.swift`
- Modify: `ios/BirthdayMobile/App/BirthdayMobileApp.swift`

**Interfaces:**
- Consumes: `BirthdayStore.activeBirthdays()`, `BirthdayRecord`
- Produces: `AppModel.reload()`, `CalendarHomeView`, three-tab app shell

- [ ] **Step 1: Write a failing view-model test in the core package for month grouping**

Create `ios/BirthdayCore/Tests/BirthdayCoreTests/CalendarProjectionTests.swift`:

```swift
import Foundation
import Testing
@testable import BirthdayCore

@Test func groupsRecordsByGregorianDayForSelectedMonth() {
    let records = [BirthdayRecord.fixture(id: UUID(), name: "妈妈", month: 8, day: 15, nextSolarDate: ISO8601DateFormatter().date(from: "2026-09-25T01:00:00Z")!)]
    let projection = CalendarProjection.make(records: records, monthContaining: ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")!, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
    #expect(projection.daysWithBirthdays == [25])
    #expect(projection.records(onDay: 25).map(\.name) == ["妈妈"])
}
```

- [ ] **Step 2: Implement `CalendarProjection` as a pure core type**

```swift
public struct CalendarProjection: Sendable {
    public let monthStart: Date
    public let recordsByDay: [Int: [BirthdayRecord]]
    public var daysWithBirthdays: [Int] { recordsByDay.keys.sorted() }
    public func records(onDay day: Int) -> [BirthdayRecord] { recordsByDay[day] ?? [] }
}
```

Add `make(records:monthContaining:timeZone:)` using a Gregorian calendar configured with the provided time zone and filtering `nextSolarDate` to the selected year and month.

- [ ] **Step 3: Run the projection test**

Run: `cd ios/BirthdayCore && swift test --filter CalendarProjectionTests`

Expected: PASS.

- [ ] **Step 4: Implement the theme and app model**

```swift
import SwiftUI

enum ModernAirTheme {
    static let teal = Color(red: 0.14, green: 0.42, blue: 0.45)
    static let blue = Color(red: 0.21, green: 0.37, blue: 0.55)
    static let background = LinearGradient(colors: [Color(red: 0.94, green: 0.98, blue: 0.98), Color(red: 0.97, green: 0.97, blue: 0.99)], startPoint: .top, endPoint: .bottom)
    static let cardRadius: CGFloat = 20
}
```

```swift
@MainActor
@Observable
final class AppModel {
    enum Tab { case calendar, birthdays, settings }
    var selectedTab: Tab = .calendar
    var records: [BirthdayRecord] = []
    var selectedMonth = Date()
    var selectedDay: Int?
    var isPresentingEditor = false
    let store: BirthdayStore

    init(store: BirthdayStore) { self.store = store }
    func reload() async { records = await store.activeBirthdays() }
}
```

- [ ] **Step 5: Implement the calendar home and app shell**

`CalendarHomeView` must render a seven-column `LazyVGrid`, add a visible marker for `CalendarProjection.daysWithBirthdays`, show records for the selected day below the grid, and place the add button in the navigation toolbar. Use `.thinMaterial` cards, `ModernAirTheme.teal`, dynamic type text styles, and accessibility labels containing both Gregorian and lunar dates.

```swift
TabView(selection: $model.selectedTab) {
    NavigationStack { CalendarHomeView(model: model) }
        .tabItem { Label("日历", systemImage: "calendar") }.tag(AppModel.Tab.calendar)
    NavigationStack { BirthdayListView(model: model) }
        .tabItem { Label("全部", systemImage: "list.bullet") }.tag(AppModel.Tab.birthdays)
    NavigationStack { SettingsView(model: model) }
        .tabItem { Label("设置", systemImage: "gearshape") }.tag(AppModel.Tab.settings)
}
```

Use temporary compile-safe `BirthdayListView` and `SettingsView` stubs in their final paths; later tasks replace their bodies.

Replace the Task 1 app entry with explicit SwiftData dependency assembly:

```swift
import SwiftData
import SwiftUI
import BirthdayCore

@main
struct BirthdayMobileApp: App {
    private let container: ModelContainer
    @State private var model: AppModel

    init() {
        let container = try! ModelContainer(for: BirthdayEntity.self, SyncOperationEntity.self)
        self.container = container
        _model = State(initialValue: AppModel(store: BirthdayStore(modelContainer: container)))
    }

    var body: some Scene {
        WindowGroup { RootTabView(model: model).task { await model.reload() } }
            .modelContainer(container)
    }
}
```

- [ ] **Step 6: Build and inspect SwiftUI previews**

Run: `cd ios && xcodegen generate && xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: build succeeds; previews compile with sample records.

- [ ] **Step 7: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Domain/CalendarProjection.swift ios/BirthdayCore/Tests/BirthdayCoreTests/CalendarProjectionTests.swift ios/BirthdayMobile/App ios/BirthdayMobile/Design ios/BirthdayMobile/Features/Calendar ios/BirthdayMobile/Features/Birthdays/BirthdayListView.swift ios/BirthdayMobile/Features/Settings/SettingsView.swift
git commit -m "feat(ios): 构建月历首页与应用导航"
```

---

### Task 9: Implement Birthday List, Search, and Grouped Editor

**Files:**
- Modify: `ios/BirthdayMobile/Features/Birthdays/BirthdayListView.swift`
- Create: `ios/BirthdayMobile/Features/Birthdays/BirthdayEditorView.swift`
- Create: `ios/BirthdayMobile/Features/Birthdays/BirthdayEditorModel.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/BirthdaySearchTests.swift`

**Interfaces:**
- Consumes: `AppModel.records`, `BirthdayStore.save`, `BirthdayStore.softDelete`, `BirthdayValidator`
- Produces: searchable list; grouped create/edit form; retained input on failure

- [ ] **Step 1: Write a failing diacritic-insensitive search test**

```swift
import Foundation
import Testing
@testable import BirthdayCore

@Test func filtersByTrimmedCaseInsensitiveName() {
    let records = [
        BirthdayRecord.fixture(id: UUID(), name: "Alice", month: 1, day: 1),
        BirthdayRecord.fixture(id: UUID(), name: "妈妈", month: 8, day: 15),
    ]
    #expect(BirthdaySearch.filter(records, query: " alice ").map(\.name) == ["Alice"])
    #expect(BirthdaySearch.filter(records, query: "妈").map(\.name) == ["妈妈"])
}
```

- [ ] **Step 2: Implement search and verify**

```swift
public enum BirthdaySearch {
    public static func filter(_ records: [BirthdayRecord], query: String) -> [BirthdayRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return records }
        return records.filter { $0.name.localizedStandardContains(needle) }
    }
}
```

Run: `cd ios/BirthdayCore && swift test --filter BirthdaySearchTests`

Expected: PASS.

- [ ] **Step 3: Implement the editor model with non-destructive errors**

```swift
@MainActor
@Observable
final class BirthdayEditorModel {
    var draft: BirthdayDraft
    var errorMessage: String?
    private let store: BirthdayStore
    private let id: UUID?

    init(store: BirthdayStore, record: BirthdayRecord?) {
        self.store = store
        self.id = record?.id
        self.draft = record.map(BirthdayDraft.init(record:)) ?? BirthdayDraft(name: "", lunarBirthday: .init(month: 1, day: 1, isLeapMonth: false), reminder: .defaults)
    }

    func save() async -> Bool {
        do {
            _ = try await store.save(draft, id: id, now: .now, timeZone: .current)
            errorMessage = nil
            return true
        } catch {
            errorMessage = BirthdayErrorMessage.text(for: error)
            return false
        }
    }
}
```

Add these exact mapping and error-copy helpers:

```swift
extension BirthdayDraft {
    init(record: BirthdayRecord) {
        self.init(name: record.name, lunarBirthday: record.lunarBirthday, reminder: record.reminder)
    }
}

enum BirthdayErrorMessage {
    static func text(for error: Error) -> String {
        switch error as? BirthdayValidationError {
        case .emptyName: return "请输入姓名"
        case .nameTooLong: return "姓名不能超过 64 个字符"
        case .invalidLunarMonth, .invalidLunarDay: return "请选择有效的农历生日"
        case .invalidReminderTime: return "请选择有效提醒时间"
        case .noNotificationSelected: return "至少开启一种本地提醒"
        case .invalidEmail: return "请输入有效收件邮箱"
        case nil: return "保存失败，输入内容已保留，请重试"
        }
    }
}
```

- [ ] **Step 4: Implement the confirmed grouped form**

`BirthdayEditorView` must use a `Form` with these exact sections and controls:

```swift
Form {
    Section("基本信息") {
        TextField("姓名", text: $model.draft.name)
        LunarDatePicker(value: $model.draft.lunarBirthday)
        Toggle("闰月", isOn: $model.draft.lunarBirthday.isLeapMonth)
    }
    Section("提醒") {
        ReminderTimePicker(minutes: $model.draft.reminder.timeMinutes)
        Toggle("提前一天", isOn: $model.draft.reminder.notifyDayBefore)
        Toggle("生日当天", isOn: $model.draft.reminder.notifySameDay)
        Toggle("邮件备份提醒", isOn: $model.draft.reminder.emailEnabled)
    }
    if model.draft.reminder.emailEnabled {
        Section("邮件") {
            TextField("收件邮箱", text: $model.draft.reminder.emailAddress)
                .textInputAutocapitalization(.never).keyboardType(.emailAddress)
            TextField("提醒内容", text: $model.draft.reminder.emailMessage, axis: .vertical)
        }
    }
}
```

Implement the two controls with these bindings; keep the sheet open when `save()` returns false:

```swift
struct LunarDatePicker: View {
    @Binding var value: LunarBirthday
    var body: some View {
        HStack {
            Picker("农历月份", selection: $value.month) { ForEach(1...12, id: \.self) { Text("\($0)月") } }
            Picker("农历日期", selection: $value.day) { ForEach(1...30, id: \.self) { Text("\($0)日") } }
        }
        .pickerStyle(.wheel)
        .frame(height: 140)
    }
}

struct ReminderTimePicker: View {
    @Binding var minutes: Int
    private var date: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(from: DateComponents(hour: minutes / 60, minute: minutes % 60)) ?? .now
            },
            set: {
                let components = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes = (components.hour ?? 9) * 60 + (components.minute ?? 0)
            }
        )
    }
    var body: some View { DatePicker("提醒时间", selection: date, displayedComponents: .hourAndMinute) }
}
```

- [ ] **Step 5: Implement list, search, edit, and soft delete**

`BirthdayListView` uses `.searchable(text:prompt:)`, sorts active records by `nextSolarDate`, opens the editor on row tap, and calls `BirthdayStore.softDelete` only after a confirmation dialog. The edit sheet includes a destructive “删除生日” action for existing records; it only opens that confirmation and never deletes on first tap. After save/delete, call `AppModel.reload()`; the add button remains in the navigation toolbar.

- [ ] **Step 6: Build and run all tests**

Run: `cd ios/BirthdayCore && swift test`

Expected: all tests PASS.

Run: `cd ios && xcodegen generate && xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Domain/BirthdaySearch.swift ios/BirthdayCore/Tests/BirthdayCoreTests/BirthdaySearchTests.swift ios/BirthdayMobile/Features/Birthdays
git commit -m "feat(ios): 增加生日列表与分组编辑页"
```

---

### Task 10: Add Onboarding, App Lock, and Local Settings

**Files:**
- Create: `ios/BirthdayMobile/Features/Onboarding/OnboardingView.swift`
- Create: `ios/BirthdayMobile/Features/Lock/AppLockView.swift`
- Modify: `ios/BirthdayMobile/Features/Settings/SettingsView.swift`
- Modify: `ios/BirthdayMobile/App/AppModel.swift`
- Modify: `ios/BirthdayMobile/App/BirthdayMobileApp.swift`

**Interfaces:**
- Consumes: `AppLockAuthenticating`, `NotificationScheduling`, `NotificationHealth`, `ReminderPlanner`
- Produces: first-run state machine, lock-on-background, visible reminder health, manual local rebuild

- [ ] **Step 1: Write failing state-machine tests**

Create `ios/BirthdayCore/Tests/BirthdayCoreTests/AppLaunchStateTests.swift`:

```swift
import Testing
@testable import BirthdayCore

@Test func firstLaunchShowsOnboardingBeforeLock() {
    #expect(AppLaunchState.resolve(hasCompletedOnboarding: false, lockEnabled: true) == .onboarding)
}

@Test func returningLockedUserShowsLock() {
    #expect(AppLaunchState.resolve(hasCompletedOnboarding: true, lockEnabled: true) == .locked)
}

@Test func unlockedUserShowsApplication() {
    #expect(AppLaunchState.resolve(hasCompletedOnboarding: true, lockEnabled: false) == .ready)
}
```

- [ ] **Step 2: Implement and verify the pure launch state**

```swift
public enum AppLaunchState: Equatable, Sendable {
    case onboarding, locked, ready
    public static func resolve(hasCompletedOnboarding: Bool, lockEnabled: Bool) -> Self {
        if !hasCompletedOnboarding { return .onboarding }
        return lockEnabled ? .locked : .ready
    }
}
```

Run: `cd ios/BirthdayCore && swift test --filter AppLaunchStateTests`

Expected: PASS.

- [ ] **Step 3: Implement onboarding without premature permission prompts**

`OnboardingView` has two pages: “离线也能完整使用” with a “继续” button, then “由 iPhone 按时提醒” with “开启通知”和“暂不开启”。Only the explicit “开启通知” button calls `UNUserNotificationCenter.requestAuthorization(options: [.alert,.sound,.badge])`; “暂不开启” completes onboarding without requesting permission. Server binding is not present until the integration plan.

- [ ] **Step 4: Implement app locking and lifecycle behavior**

`AppModel` stores `hasCompletedOnboarding` and `lockEnabled` in `UserDefaults`, registers `lockEnabled=true` as the first-run default, sets `isUnlocked=false` when scene phase becomes background, and calls `AppLockAuthenticating.unlock(reason: "解锁生日资料")` only after the user taps the unlock button. `AppLockView` must show real failures and allow retry; do not loop authentication automatically.

- [ ] **Step 5: Implement local settings and reminder health**

`SettingsView` displays:

- Face ID lock toggle
- actual notification authorization state
- scheduled count and coverage end date
- “重新安排本地提醒” button
- “服务器同步将在后续步骤启用” disabled row

The rebuild button loads active records, calls `ReminderPlanner.makePlan`, then `NotificationScheduling.apply`. Display `.scheduled`, `.permissionDenied`, `.notRequested`, and `.failed` with icon plus text, never color alone.

- [ ] **Step 6: Run tests and build**

Run: `cd ios/BirthdayCore && swift test`

Expected: all tests PASS.

Run: `cd ios && xcodegen generate && xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Domain/AppLaunchState.swift ios/BirthdayCore/Tests/BirthdayCoreTests/AppLaunchStateTests.swift ios/BirthdayMobile/App ios/BirthdayMobile/Features/Onboarding ios/BirthdayMobile/Features/Lock ios/BirthdayMobile/Features/Settings
git commit -m "feat(ios): 完成首次启动与本地隐私设置"
```

---

### Task 11: Verify the Offline-Only Milestone

**Files:**
- Create: `ios/QA/OFFLINE_ACCEPTANCE.md`
- Modify: `ios/project.yml`
- Modify: `ios/BirthdayMobile/App/BirthdayMobileApp.swift`
- Modify: `ios/BirthdayMobile/App/AppModel.swift`

**Interfaces:**
- Consumes: all deliverables from Tasks 1-10
- Produces: reproducible offline acceptance evidence; no new product capability

- [ ] **Step 1: Add UI-test target configuration**

Extend `ios/project.yml`:

```yaml
  BirthdayMobileUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - BirthdayMobileUITests
    dependencies:
      - target: BirthdayMobile
```

Create `ios/BirthdayMobileUITests/OfflineFlowUITests.swift` with a launch argument that injects an in-memory store and disables actual Face ID:

```swift
import XCTest

final class OfflineFlowUITests: XCTestCase {
    func testCreateSearchEditAndDeleteWithoutNetwork() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-network-disabled"]
        app.launch()
        XCTAssertTrue(app.staticTexts["离线也能完整使用"].waitForExistence(timeout: 3))
        app.buttons["继续"].tap()
        app.buttons["暂不开启"].tap()
        if app.buttons["unlockButton"].waitForExistence(timeout: 1) {
            app.buttons["unlockButton"].tap()
        }

        app.buttons["addBirthdayButton"].tap()
        let name = app.textFields["birthdayNameField"]
        name.tap()
        name.typeText("妈妈")
        app.buttons["saveBirthdayButton"].tap()
        app.tabBars.buttons["全部"].tap()
        XCTAssertTrue(app.staticTexts["妈妈"].waitForExistence(timeout: 2))

        let search = app.searchFields["birthdaySearchField"]
        search.tap()
        search.typeText("妈妈")
        app.staticTexts["妈妈"].tap()
        name.tap()
        name.clearAndEnterText("妈妈更新")
        app.buttons["saveBirthdayButton"].tap()
        XCTAssertTrue(app.staticTexts["妈妈更新"].waitForExistence(timeout: 2))

        app.staticTexts["妈妈更新"].tap()
        app.buttons["deleteBirthdayButton"].tap()
        app.buttons["确认删除"].tap()
        XCTAssertFalse(app.staticTexts["妈妈更新"].exists)
    }
}
```

Add stable accessibility identifiers in the production views: `unlockButton`, `addBirthdayButton`, `birthdayNameField`, `saveBirthdayButton`, `birthdaySearchField`, and `deleteBirthdayButton`. Add this test-only helper in the UI-test target:

```swift
extension XCUIElement {
    func clearAndEnterText(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
```

Wire those arguments explicitly in the app composition root. Add a `UITestBootstrap` value that is read before `AppModel` is created:

```swift
struct UITestBootstrap {
    let isEnabled: Bool
    let networkDisabled: Bool
    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        isEnabled = arguments.contains("-ui-testing")
        networkDisabled = arguments.contains("-network-disabled")
    }
}
```

When `isEnabled` is true, `BirthdayMobileApp` creates `ModelConfiguration(isStoredInMemoryOnly: true)`, injects an app-lock authenticator that returns `true` without presenting LocalAuthentication, and skips construction of the mobile API when `networkDisabled` is true. The same composition path must still run onboarding, so the UI test can assert “离线也能完整使用”. Production launch arguments continue to create the on-disk container and real services.

- [ ] **Step 2: Document exact physical-device acceptance checks**

`ios/QA/OFFLINE_ACCEPTANCE.md` must contain these checkboxes:

```markdown
- [ ] 开启飞行模式后新增生日并立即出现在月历和全部列表
- [ ] 强制退出并重新打开后数据仍存在
- [ ] 编辑和删除均不等待网络
- [ ] 通知权限允许时，系统设置中可看到已安排请求
- [ ] 临时创建两分钟后的测试生日，锁屏状态收到本地通知
- [ ] Face ID 成功、失败和设备密码回退均符合界面状态
- [ ] 设置页显示安排数量和覆盖截止日期
- [ ] 动态字体最大级别下表单仍可滚动并完成保存
- [ ] VoiceOver 能读出公历、农历、姓名和同步状态
```

- [ ] **Step 3: Run automated verification**

Run: `cd ios/BirthdayCore && swift test`

Expected: all core tests PASS.

Run: `cd ios && xcodegen generate`

Expected: project generation succeeds.

Run: `xcodebuild -project ios/BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: `** BUILD SUCCEEDED **`.

If CoreSimulatorService is available, additionally run:

`xcodebuild -project ios/BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' test`

Expected: core-linked app tests and UI launch test PASS. If the simulator service is unavailable, record that as environment coverage and do not claim UI automation passed.

- [ ] **Step 4: Run repository checks**

Run: `git diff --check`

Expected: no whitespace errors.

Run: `git status --short`

Expected: only intentionally changed iOS files plus the user's pre-existing unrelated changes.

- [ ] **Step 5: Commit**

```bash
git add ios/project.yml ios/BirthdayMobileUITests ios/BirthdayMobile/App/BirthdayMobileApp.swift ios/BirthdayMobile/App/AppModel.swift ios/BirthdayMobile/Features/Birthdays ios/QA/OFFLINE_ACCEPTANCE.md
git commit -m "test(ios): 验证本地离线核心流程"
```
