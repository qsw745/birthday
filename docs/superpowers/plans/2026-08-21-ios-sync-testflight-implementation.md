# iOS Sync and TestFlight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将已验收的 iOS 离线核心绑定到移动同步 API，实现首次导入、后台增量同步、冲突选择、设备管理和可验证的 TestFlight 构建。

**Architecture:** `BirthdayCore` 增加 DTO、API client、快照导入、同步引擎和冲突持久化；SwiftUI 应用只观察本地状态并通过显式用例触发同步。同步完成后统一重建本地通知窗口，后台任务与网络恢复仅作为自动触发器。

**Tech Stack:** Swift 6.3、Foundation URLSession、Network、BackgroundTasks、SwiftData、Keychain、SwiftUI、XcodeGen、XCTest/Swift Testing、Node mobile sync API

**Spec:** `docs/superpowers/specs/2026-08-21-ios-local-first-birthday-app-design.md`

## Global Constraints

- 必须先完成 `2026-08-21-ios-local-core-implementation.md` 和 `2026-08-21-mobile-sync-server-implementation.md`。
- 三份计划在同一个由 `superpowers:using-git-worktrees` 创建的隔离工作树中顺序执行；不要直接修改当前脏工作区。
- 本地 SwiftData 始终是界面事实来源；任何 API 请求不得直接驱动页面数据。
- 首次快照导入必须事务化；任一 DTO 无效时不得写入部分数据或推进游标。
- 版本和游标在 JSON 中使用十进制字符串，转换为 `Int64` 前必须检查溢出。
- 同步冲突必须保存本机与云端双方；不得自动使用“最后写入获胜”。
- 访问令牌和刷新令牌只存 Keychain；不得存入 `UserDefaults`、SwiftData 或日志。
- 401 只允许自动刷新并重放一次；再次失败进入“需要重新绑定”状态。
- 后台任务不保证准时，准时生日提醒仍由已安排的本地通知负责。
- 解绑设备只停止同步并删除令牌，不删除本地生日资料。
- TestFlight 前必须完成真机 Face ID、本地通知和飞行模式回归；模拟器不能代替。
- 归档证据完成后仍必须再次获得用户明确确认，才能上传 TestFlight；准备完成不等于已提交、已处理或测试者可用。
- 保留用户原有未提交文件，不部署或修改生产服务器，除非服务器计划已完成且用户另行确认切换。

---

## File Structure

- `ios/BirthdayCore/Sources/BirthdayCore/Sync/MobileSyncDTO.swift`：API 请求响应和严格解码。
- `ios/BirthdayCore/Sources/BirthdayCore/Sync/MobileAPIClient.swift`：URLSession 请求、401 刷新钩子和错误分类。
- `ios/BirthdayCore/Sources/BirthdayCore/Sync/DeviceCredentialStore.swift`：设备 ID 和 Keychain token bundle。
- `ios/BirthdayCore/Sources/BirthdayCore/Sync/SnapshotImporter.swift`：导入预检、疑似重复和原子写入。
- `ios/BirthdayCore/Sources/BirthdayCore/Sync/SyncEngine.swift`：上传、拉取、游标和退避。
- `ios/BirthdayCore/Sources/BirthdayCore/Data/SyncConflictEntity.swift`：冲突双方快照。
- `ios/BirthdayCore/Sources/BirthdayCore/Sync/ConflictResolver.swift`：保留本机或使用云端。
- `ios/BirthdayMobile/Sync/SyncCoordinator.swift`：scene、网络与后台任务触发器。
- `ios/BirthdayMobile/Features/Onboarding/ServerBindingView.swift`：账号绑定和首次导入。
- `ios/BirthdayMobile/Features/Settings/SyncSettingsView.swift`：状态、手动同步、设备和解绑。
- `ios/BirthdayMobile/Features/Conflicts/ConflictListView.swift`：冲突列表与双版本选择。
- `ios/BirthdayMobile/Config/Debug.xcconfig`：开发 API 地址。
- `ios/BirthdayMobile/Config/Release.xcconfig`：正式 API 地址。
- `ios/QA/TESTFLIGHT_ACCEPTANCE.md`：TestFlight 证据清单。

---

### Task 1: Lock the Swift API Contract with DTO Tests

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Sync/MobileSyncDTO.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/MobileSyncDTOTests.swift`

**Interfaces:**
- Consumes: server contract in `docs/mobile-sync-api.md`
- Produces: `APIBirthday`, `SnapshotResponse`, `PullResponse`, `PushRequest`, `PushResult`, `TokenResponse`

- [ ] **Step 1: Write failing DTO decode tests using exact server JSON**

```swift
import Foundation
import Testing
@testable import BirthdayCore

@Test func decodesSnapshotWithStringCursorAndVersion() throws {
    let json = #"{"cursor":"41","birthdays":[{"id":"11111111-1111-4111-8111-111111111111","name":"妈妈","lunarMonth":8,"lunarDay":15,"isLeapMonth":false,"reminderTimeMinutes":540,"notifyDayBefore":true,"notifySameDay":true,"emailEnabled":true,"emailAddress":"a@example.com","emailMessage":"生日快乐","nextSolarDate":"2026-09-25T01:00:00.000Z","version":"3","createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-08-01T00:00:00.000Z","deletedAt":null}]}"#.data(using: .utf8)!
    let snapshot = try MobileJSON.decoder.decode(SnapshotResponse.self, from: json)
    #expect(snapshot.cursor == 41)
    #expect(snapshot.birthdays.first?.version == 3)
    #expect(snapshot.birthdays.first?.reminder.timeMinutes == 540)
}

@Test func rejectsOverflowingCursor() {
    let json = #"{"cursor":"999999999999999999999999","birthdays":[]}"#.data(using: .utf8)!
    #expect(throws: DecodingError.self) {
        try MobileJSON.decoder.decode(SnapshotResponse.self, from: json)
    }
}
```

- [ ] **Step 2: Run and verify DTO symbols are missing**

Run: `cd ios/BirthdayCore && swift test --filter MobileSyncDTOTests`

Expected: compile failure.

- [ ] **Step 3: Implement strict string-integer decoding and date strategy**

```swift
import Foundation

public enum MobileJSON {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            guard let date = basic.date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid ISO-8601 date"))
            }
            return date
        }
        return decoder
    }()
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()
}

public struct DecimalInt64: Codable, Equatable, Sendable {
    public let value: Int64
    public init(_ value: Int64) { self.value = value }
    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let value = Int64(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid int64 string"))
        }
        self.value = value
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(value))
    }
}

public struct APIBirthday: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let lunarMonth: Int
    public let lunarDay: Int
    public let isLeapMonth: Bool
    public let reminderTimeMinutes: Int
    public let notifyDayBefore: Bool
    public let notifySameDay: Bool
    public let emailEnabled: Bool
    public let emailAddress: String
    public let emailMessage: String
    public let nextSolarDate: Date?
    private let versionValue: DecimalInt64
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?
    public var version: Int64 { versionValue.value }
    enum CodingKeys: String, CodingKey { case id, name, lunarMonth, lunarDay, isLeapMonth, reminderTimeMinutes, notifyDayBefore, notifySameDay, emailEnabled, emailAddress, emailMessage, nextSolarDate, versionValue = "version", createdAt, updatedAt, deletedAt }
    public var reminder: ReminderConfig { ReminderConfig(timeMinutes: reminderTimeMinutes, notifyDayBefore: notifyDayBefore, notifySameDay: notifySameDay, emailEnabled: emailEnabled, emailAddress: emailAddress, emailMessage: emailMessage) }
    public init(id: UUID, name: String, lunarMonth: Int, lunarDay: Int, isLeapMonth: Bool, reminder: ReminderConfig, nextSolarDate: Date?, version: Int64, createdAt: Date, updatedAt: Date, deletedAt: Date?) {
        self.id = id; self.name = name; self.lunarMonth = lunarMonth; self.lunarDay = lunarDay; self.isLeapMonth = isLeapMonth
        self.reminderTimeMinutes = reminder.timeMinutes; self.notifyDayBefore = reminder.notifyDayBefore; self.notifySameDay = reminder.notifySameDay
        self.emailEnabled = reminder.emailEnabled; self.emailAddress = reminder.emailAddress; self.emailMessage = reminder.emailMessage
        self.nextSolarDate = nextSolarDate; self.versionValue = DecimalInt64(version); self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }
}

public struct SnapshotResponse: Codable, Equatable, Sendable {
    private let cursorValue: DecimalInt64
    public let birthdays: [APIBirthday]
    public var cursor: Int64 { cursorValue.value }
    enum CodingKeys: String, CodingKey { case cursorValue = "cursor", birthdays }
    public init(cursor: Int64, birthdays: [APIBirthday]) { self.cursorValue = DecimalInt64(cursor); self.birthdays = birthdays }
}

public struct LoginRequest: Codable, Equatable, Sendable {
    public let username: String
    public let password: String
    public let deviceId: UUID
    public let deviceName: String
}

public struct RefreshRequest: Codable, Equatable, Sendable {
    public let refreshToken: String
}

public struct TokenResponse: Codable, Equatable, Sendable {
    public let deviceId: UUID
    public let accessToken: String
    public let accessExpiresAt: Date
    public let refreshToken: String
    public let refreshExpiresAt: Date
    public init(deviceId: UUID, accessToken: String, accessExpiresAt: Date, refreshToken: String, refreshExpiresAt: Date) {
        self.deviceId = deviceId; self.accessToken = accessToken; self.accessExpiresAt = accessExpiresAt
        self.refreshToken = refreshToken; self.refreshExpiresAt = refreshExpiresAt
    }
}

public struct BirthdayPayloadDTO: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let lunarMonth: Int
    public let lunarDay: Int
    public let isLeapMonth: Bool
    public let reminderTimeMinutes: Int
    public let notifyDayBefore: Bool
    public let notifySameDay: Bool
    public let emailEnabled: Bool
    public let emailAddress: String
    public let emailMessage: String
}

public enum PushOperationKind: String, Codable, Sendable { case upsert, delete }

public struct PushOperationDTO: Codable, Equatable, Sendable {
    public let operationId: UUID
    public let entityId: UUID
    public let type: PushOperationKind
    private let baseVersionValue: DecimalInt64
    public let payload: BirthdayPayloadDTO?
    public var baseVersion: Int64 { baseVersionValue.value }
    enum CodingKeys: String, CodingKey { case operationId, entityId, type, baseVersionValue = "baseVersion", payload }
}

public struct PushRequest: Codable, Equatable, Sendable {
    public let operations: [PushOperationDTO]
}

public enum PushResultStatus: String, Codable, Sendable { case applied, conflict }

public struct PushResult: Codable, Equatable, Sendable {
    public let operationId: UUID
    public let status: PushResultStatus
    public let record: APIBirthday?
    public let remote: APIBirthday?
}

public struct PushResponse: Codable, Equatable, Sendable {
    public let results: [PushResult]
    public init(results: [PushResult]) { self.results = results }
}

public enum PullOperation: String, Codable, Sendable { case upsert, delete }

public struct PullChange: Codable, Equatable, Sendable {
    private let seqValue: DecimalInt64
    public let operation: PullOperation
    public let record: APIBirthday
    public var seq: Int64 { seqValue.value }
    enum CodingKeys: String, CodingKey { case seqValue = "seq", operation, record }
}

public struct PullResponse: Codable, Equatable, Sendable {
    public let changes: [PullChange]
    private let nextCursorValue: DecimalInt64
    public let hasMore: Bool
    public var nextCursor: Int64 { nextCursorValue.value }
    enum CodingKeys: String, CodingKey { case changes, nextCursorValue = "nextCursor", hasMore }
    public init(changes: [PullChange], nextCursor: Int64, hasMore: Bool) {
        self.changes = changes; self.nextCursorValue = DecimalInt64(nextCursor); self.hasMore = hasMore
    }
}

public struct MobileDevice: Codable, Equatable, Sendable {
    public let deviceId: UUID
    public let deviceName: String
    public let createdAt: Date
    public let lastUsedAt: Date?
    public let revokedAt: Date?
}
```

Add `APIBirthday.asRecord(syncState:)` that copies every field into `BirthdayRecord`. Add explicit public initializers for the request/response types used by fakes. Throwing `PushOperationDTO.init(_ operation: SyncOperation)` decodes `operation.payloadJSON` into `BirthdayPayloadDTO` for upserts and uses `nil` for deletes; also add `BirthdayPayloadDTO.init(record:)`. All custom coding keys shown above must remain exact so server fixtures and Swift tests share one contract.

- [ ] **Step 4: Run DTO tests**

Run: `cd ios/BirthdayCore && swift test --filter MobileSyncDTOTests`

Expected: valid snapshot, tombstone, applied result, conflict result, malformed date, and overflowing integer tests PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Sync/MobileSyncDTO.swift ios/BirthdayCore/Tests/BirthdayCoreTests/MobileSyncDTOTests.swift
git commit -m "feat(ios): 定义移动同步数据契约"
```

---

### Task 2: Implement API Client and Error Classification

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Sync/MobileAPIClient.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/MobileAPIClientTests.swift`

**Interfaces:**
- Consumes: `URLSession`, DTOs, bearer access token
- Produces: `MobileAPI.snapshot`, `pull`, `push`, `login`, `refresh`, `revoke`, `devices`

- [ ] **Step 1: Write failing URLProtocol-backed tests**

```swift
import Foundation
import Testing
@testable import BirthdayCore

final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

extension URLSession {
    static var stubbed: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

@Test func snapshotSendsBearerTokenAndDecodesBody() async throws {
    URLProtocolStub.handler = { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        let body = #"{"cursor":"0","birthdays":[]}"#.data(using: .utf8)!
        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
    }
    let api = MobileAPIClient(baseURL: URL(string: "https://qisw.top/api/mobile")!, session: .stubbed)
    #expect(try await api.snapshot(accessToken: "access").cursor == 0)
}

@Test func classifiesUnauthorizedResponse() async {
    URLProtocolStub.handler = { request in
        (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, #"{"error":"mobile_access_expired"}"#.data(using: .utf8)!)
    }
    let api = MobileAPIClient(baseURL: URL(string: "https://qisw.top/api/mobile")!, session: .stubbed)
    await #expect(throws: MobileAPIError.accessExpired) { try await api.snapshot(accessToken: "expired") }
}
```

- [ ] **Step 2: Implement request construction and stable errors**

```swift
public enum MobileAPIError: Error, Equatable {
    case accessExpired, refreshInvalid, invalidResponse, server(code: String, status: Int), transport(String)
}

public protocol MobileAPI: Sendable {
    func login(_ request: LoginRequest) async throws -> TokenResponse
    func refresh(_ request: RefreshRequest) async throws -> TokenResponse
    func snapshot(accessToken: String) async throws -> SnapshotResponse
    func push(_ request: PushRequest, accessToken: String) async throws -> PushResponse
    func pull(cursor: Int64, accessToken: String) async throws -> PullResponse
    func revoke(deviceId: UUID, accessToken: String) async throws
    func devices(accessToken: String) async throws -> [MobileDevice]
}
```

`MobileAPIClient` builds URLs only by appending known path components to `baseURL`, sets `Content-Type: application/json`, applies a 20-second request timeout, and maps 401 codes exactly. For non-2xx responses, decode `{ error: String }`; never include response bodies or tokens in error descriptions.

- [ ] **Step 3: Run client tests**

Run: `cd ios/BirthdayCore && swift test --filter MobileAPIClientTests`

Expected: authorization header, login body, push body, pull cursor, 401, 409 payload, malformed JSON, and transport cases PASS.

- [ ] **Step 4: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Sync/MobileAPIClient.swift ios/BirthdayCore/Tests/BirthdayCoreTests/MobileAPIClientTests.swift
git commit -m "feat(ios): 实现移动同步 API 客户端"
```

---

### Task 3: Store Device Credentials and Bind the Server

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Sync/DeviceCredentialStore.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/DeviceCredentialStoreTests.swift`
- Create: `ios/BirthdayMobile/Features/Onboarding/ServerBindingView.swift`
- Modify: `ios/BirthdayMobile/Features/Onboarding/OnboardingView.swift`

**Interfaces:**
- Consumes: `MobileAPI.login`, `SecureTokenStore`
- Produces: `DeviceCredentialStore.load/save/clear`, server-binding UI

- [ ] **Step 1: Write failing Keychain bundle tests**

```swift
import Foundation
import Testing
@testable import BirthdayCore

@Test func credentialStorePersistsTokensOutsideSwiftData() throws {
    let secure = InMemorySecureTokenStore()
    let store = DeviceCredentialStore(secure: secure)
    let credentials = DeviceCredentials(deviceId: UUID(), accessToken: "a", accessExpiresAt: .now.addingTimeInterval(900), refreshToken: "r", refreshExpiresAt: .now.addingTimeInterval(15_552_000))
    try store.save(credentials)
    #expect(try store.load() == credentials)
    #expect(secure.accounts == ["mobile-device-credentials"])
}
```

- [ ] **Step 2: Implement one encoded credential bundle in Keychain**

```swift
public struct DeviceCredentials: Codable, Equatable, Sendable {
    public let deviceId: UUID
    public let accessToken: String
    public let accessExpiresAt: Date
    public let refreshToken: String
    public let refreshExpiresAt: Date
}

public struct DeviceCredentialStore: Sendable {
    private let secure: any SecureTokenStore
    private let account = "mobile-device-credentials"
    public init(secure: any SecureTokenStore) { self.secure = secure }
    public func save(_ value: DeviceCredentials) throws { try secure.save(MobileJSON.encoder.encode(value), account: account) }
    public func load() throws -> DeviceCredentials? {
        guard let data = try secure.read(account: account) else { return nil }
        return try MobileJSON.decoder.decode(DeviceCredentials.self, from: data)
    }
    public func clear() throws { try secure.delete(account: account) }
}
```

- [ ] **Step 3: Run credential tests**

Run: `cd ios/BirthdayCore && swift test --filter DeviceCredentialStoreTests`

Expected: save, load, overwrite, corrupt-data, and clear cases PASS.

- [ ] **Step 4: Implement explicit server binding UI**

`ServerBindingView` contains username, secure password, editable device name defaulting to `UIDevice.current.name`, “绑定并导入” and “暂不绑定”. It calls login only from the button action, clears the password after completion, saves the token response in Keychain, and moves to snapshot preview. Error text maps `401` to“用户名或密码错误” and transport failure to“暂时无法连接服务器，本地功能仍可使用”.

- [ ] **Step 5: Build and commit**

Run: `cd ios/BirthdayCore && swift test`

Expected: all tests PASS.

Run: `cd ios && xcodegen generate && xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: build succeeds.

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Sync/DeviceCredentialStore.swift ios/BirthdayCore/Tests/BirthdayCoreTests/DeviceCredentialStoreTests.swift ios/BirthdayMobile/Features/Onboarding
git commit -m "feat(ios): 增加服务器设备绑定"
```

---

### Task 4: Import the First Snapshot Atomically

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Sync/SnapshotImporter.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/SnapshotImporterTests.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/SyncTestFixtures.swift`
- Modify: `ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayStore.swift`
- Modify: `ios/BirthdayMobile/Features/Onboarding/ServerBindingView.swift`
- Modify: `ios/BirthdayMobile/App/BirthdayMobileApp.swift`

**Interfaces:**
- Consumes: `SnapshotResponse`, existing local records
- Produces: `SnapshotImportPreview`, `DuplicateDecision`, `BirthdayStore.applySnapshot(_:cursor:decisions:)`

- [ ] **Step 1: Write failing preview and rollback tests**

```swift
import Foundation
import SwiftData
import Testing
@testable import BirthdayCore

func makeSyncStore() throws -> BirthdayStore {
    let container = try ModelContainer(for: BirthdayEntity.self, SyncOperationEntity.self, SyncMetadataEntity.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return BirthdayStore(modelContainer: container)
}

func makeAPIBirthday(id: UUID = UUID(), name: String = "妈妈", month: Int = 8, day: Int = 15, version: Int64 = 1) -> APIBirthday {
    APIBirthday(id: id, name: name, lunarMonth: month, lunarDay: day, isLeapMonth: false, reminder: .defaults, nextSolarDate: nil, version: version, createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000), deletedAt: nil)
}

@Test func previewFlagsSameNameAndLunarDateWithDifferentIds() {
    let local = BirthdayRecord.fixture(id: UUID(), name: "妈妈", month: 8, day: 15)
    let remote = makeAPIBirthday(id: UUID(), name: "妈妈", month: 8, day: 15)
    let preview = SnapshotImporter.preview(local: [local], remote: [remote])
    #expect(preview.duplicates.count == 1)
}

@Test func invalidSnapshotWritesNothingAndDoesNotAdvanceCursor() async throws {
    let store = try makeSyncStore()
    let invalid = SnapshotResponse(cursor: 41, birthdays: [makeAPIBirthday(name: "", month: 8, day: 15)])
    await #expect(throws: BirthdayValidationError.emptyName) {
        try await store.applySnapshot(invalid, decisions: [:])
    }
    #expect(await store.activeBirthdays().isEmpty)
    #expect(await store.syncCursor() == 0)
}
```

Place `makeSyncStore` and `makeAPIBirthday` in `SyncTestFixtures.swift`; test files call them without redeclaration.

- [ ] **Step 2: Implement duplicate preview with normalized keys**

```swift
public enum DuplicateDecision: String, Codable, Sendable { case keepBoth, useRemote }

public struct DuplicateCandidate: Identifiable, Sendable {
    public var id: String { "\(local.id.uuidString):\(remote.id.uuidString)" }
    public let local: BirthdayRecord
    public let remote: APIBirthday
}

public struct SnapshotImportPreview: Sendable {
    public let remoteCount: Int
    public let duplicates: [DuplicateCandidate]
}
```

Normalize by trimming name, applying `folding(options: [.caseInsensitive,.diacriticInsensitive], locale: .current)`, and combining lunar month/day/leap flag. Matching UUID is an update, not a duplicate.

- [ ] **Step 3: Implement one SwiftData transaction for import**

Add a persisted `SyncMetadataEntity` with unique key `primary` and `cursor: Int64`. `BirthdayStore.applySnapshot` validates every remote record first, then inserts/updates all accepted records, clears outbox entries only for exact matching imported IDs that have no local pending change, writes the cursor last, and calls `modelContext.save()` once. On error, call `modelContext.rollback()` and rethrow. Update the app composition root so every production and UI-test `ModelContainer` schema includes `SyncMetadataEntity` in addition to the two local-core entities.

For duplicate decisions:

- `keepBoth`: keep local UUID and import remote UUID.
- `useRemote`: soft-delete the local duplicate without creating an outbox entry, then import remote UUID.

- [ ] **Step 4: Implement import preview UI**

After login, show remote count and each suspected duplicate with the two choices. The final button says“导入 N 条生日”. Do not write until every duplicate has a decision. On successful transaction, mark onboarding complete and open the month calendar.

- [ ] **Step 5: Run tests and build**

Run: `cd ios/BirthdayCore && swift test --filter SnapshotImporterTests`

Expected: empty local, matching UUID, keep both, use remote, invalid rollback, and cursor advancement cases PASS.

Run: `cd ios && xcodegen generate && xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Sync/SnapshotImporter.swift ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayStore.swift ios/BirthdayCore/Sources/BirthdayCore/Data/SyncMetadataEntity.swift ios/BirthdayCore/Tests/BirthdayCoreTests/SnapshotImporterTests.swift ios/BirthdayCore/Tests/BirthdayCoreTests/SyncTestFixtures.swift ios/BirthdayMobile/Features/Onboarding/ServerBindingView.swift ios/BirthdayMobile/App/BirthdayMobileApp.swift
git commit -m "feat(ios): 原子导入服务器生日快照"
```

---

### Task 5: Implement Byte-Bounded Upload, Pull, Retry, and Token Refresh

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Sync/SyncEngine.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/SyncEngineTests.swift`
- Modify: `ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayStore.swift`
- Modify: `ios/BirthdayCore/Sources/BirthdayCore/Sync/DeviceCredentialStore.swift`

**Interfaces:**
- Consumes: `MobileAPI`, `BirthdayStore`, `DeviceCredentialStore`
- Produces: `SyncEngine.syncNow() -> SyncSummary`, `PushBatcher`, `RetryPolicy.delay(attempt:)`

- [ ] **Step 1: Write failing batching, retry, and one-refresh-only tests**

```swift
import Foundation
import Testing
@testable import BirthdayCore

private actor RefreshingFakeAPI: MobileAPI {
    private var pullCalls = 0
    private var refreshCalls = 0
    func login(_ request: LoginRequest) async throws -> TokenResponse { throw MobileAPIError.invalidResponse }
    func refresh(_ request: RefreshRequest) async throws -> TokenResponse {
        refreshCalls += 1
        return TokenResponse(deviceId: Self.deviceId, accessToken: "fresh-access", accessExpiresAt: Date().addingTimeInterval(900), refreshToken: "fresh-refresh", refreshExpiresAt: Date().addingTimeInterval(15_552_000))
    }
    func snapshot(accessToken: String) async throws -> SnapshotResponse { throw MobileAPIError.invalidResponse }
    func push(_ request: PushRequest, accessToken: String) async throws -> PushResponse { PushResponse(results: []) }
    func pull(cursor: Int64, accessToken: String) async throws -> PullResponse {
        pullCalls += 1
        if pullCalls == 1 { throw MobileAPIError.accessExpired }
        return PullResponse(changes: [], nextCursor: 4, hasMore: false)
    }
    func revoke(deviceId: UUID, accessToken: String) async throws {}
    func devices(accessToken: String) async throws -> [MobileDevice] { [] }
    func refreshCount() -> Int { refreshCalls }
    private static let deviceId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
}

@Test func retryPolicyCapsAtSixHours() {
    #expect(RetryPolicy.delay(attempt: 0) == 30)
    #expect(RetryPolicy.delay(attempt: 1) == 60)
    #expect(RetryPolicy.delay(attempt: 20) == 21_600)
}

@Test func expiredAccessRefreshesOnceThenReplaysSnapshot() async throws {
    let api = RefreshingFakeAPI()
    let secure = InMemorySecureTokenStore()
    let credentials = DeviceCredentialStore(secure: secure)
    try credentials.save(DeviceCredentials(deviceId: UUID(), accessToken: "access", accessExpiresAt: Date().addingTimeInterval(600), refreshToken: "refresh", refreshExpiresAt: Date().addingTimeInterval(15_552_000)))
    let engine = SyncEngine(api: api, store: try makeSyncStore(), credentials: credentials)
    let summary = try await engine.syncNow()
    #expect(summary.cursor == 4)
    #expect(await api.refreshCount() == 1)
}

@Test func pushBatcherMeasuresTheActualCompactRequestIncludingJSONEscapes() throws {
    let operations = try makeOperationsWithQuotedBackslashAndControlText()
    let batches = try PushBatcher.makeBatches(operations)
    for batch in batches {
        let data = try MobileJSON.encoder.encode(PushRequest(operations: batch))
        #expect(batch.count <= 50)
        #expect(data.count <= 61_440)
    }
}

@Test func pushBatcherKeepsAnExact61440ByteRequestAndSplitsTheNextByte() throws {
    let exact = try makePushOperationsWhoseEncodedRequestIsExactly(61_440)
    #expect(try PushBatcher.makeBatches(exact).count == 1)

    let over = try makePushOperationsWhoseEncodedRequestIsExactly(61_441)
    let batches = try PushBatcher.makeBatches(over)
    #expect(batches.count == 2)
    #expect(try batches.allSatisfy {
        try MobileJSON.encoder.encode(PushRequest(operations: $0)).count <= 61_440
    })
}

@Test func syncPushesEveryCountAndByteBatchBeforeStartingPull() async throws {
    let fixture = try makeSyncFixture(readyOperationCount: 121, escapedPayloads: true)
    _ = try await fixture.engine.syncNow()
    let events = await fixture.api.events()
    #expect(events.filter { $0 == .push }.count >= 3)
    #expect(events.lastIndex(of: .push)! < events.firstIndex(of: .pull)!)
    #expect(await fixture.store.readyOperations(limit: 500, now: .now).isEmpty)
}
```

The batching test fixtures must also cover: more than 50 individually small operations, a single largest legal operation using the shared 8192-byte `name + emailMessage` storage contract, JSON quote/backslash/control-character expansion, an encoded request exactly at 61,440 bytes, and the first byte above the boundary. Expected byte counts must be checked against the complete compact `PushRequest`, not by summing payload strings or per-operation estimates.

- [ ] **Step 2: Implement deterministic retry policy**

```swift
public enum RetryPolicy {
    public static func delay(attempt: Int) -> TimeInterval {
        min(21_600, 30 * pow(2, Double(max(0, attempt))))
    }
}
```

- [ ] **Step 3: Implement greedy count-and-byte batching**

`PushBatcher` converts ready `SyncOperation` values to `PushOperationDTO` first, then greedily appends each operation only when `MobileJSON.encoder.encode(PushRequest(operations: candidate)).count <= 61_440` and the candidate count is at most 50. `MobileJSON.encoder` is the same compact production encoder later used by `MobileAPIClient.push`; do not use a second estimator, pretty-printed JSON, payload-only byte counts, or a nominal character limit.

When the next operation would cross either limit, emit the current non-empty batch and retry that operation as the first item of a new batch. A single valid operation must fit because the shared server/client storage contract caps `name + emailMessage` at 8192 UTF-8 bytes even under JSON escaping. If a persisted operation still cannot fit by itself, classify it as a terminal local contract error instead of repeatedly fetching the same poison item forever.

- [ ] **Step 4: Implement the sync cycle in exact order and drain uploads before pull**

```swift
public struct SyncSummary: Sendable {
    public let uploaded: Int
    public let downloaded: Int
    public let conflicts: Int
    public let cursor: Int64
}

public actor SyncEngine {
    public func syncNow() async throws -> SyncSummary {
        var uploaded = 0
        var conflicts = 0
        while true {
            let ready = await store.readyOperations(limit: 200, now: .now)
            if ready.isEmpty { break }
            let batches = try PushBatcher.makeBatches(ready)
            guard !batches.isEmpty else { throw SyncError.invalidReadyOperation }
            for batch in batches {
                let push = try await authorized { access in
                    try await api.push(PushRequest(operations: batch), accessToken: access)
                }
                try await store.applyPushResults(push.results)
                uploaded += push.results.filter { $0.status == .applied }.count
                conflicts += push.results.filter { $0.status == .conflict }.count
            }
        }

        var cursor = await store.syncCursor()
        var downloaded = 0
        repeat {
            let page = try await authorized { access in try await api.pull(cursor: cursor, accessToken: access) }
            try await store.applyPull(page)
            downloaded += page.changes.count
            cursor = page.nextCursor
            if !page.hasMore { break }
        } while true
        return SyncSummary(uploaded: uploaded, downloaded: downloaded, conflicts: conflicts, cursor: cursor)
    }
}
```

The store must exclude conflict-blocked and terminally invalid operations from subsequent `readyOperations` calls. `syncNow()` may refetch finite windows, but it must continue until all currently ready operations have either received a push result or a terminal local classification; only then may the first pull begin. This ordering prevents a count/byte split from uploading only its first batch and prevents an unencodable head item from causing an infinite loop.

`authorized` loads credentials, refreshes and persists a rotated pair exactly once on `.accessExpired`, replays the original closure once, and maps a second 401 or `.refreshInvalid` to `SyncError.rebindRequired`. `validAccessToken` refreshes proactively when fewer than 60 seconds remain.

`BirthdayStore.applyPushResults` removes applied outbox rows, writes returned versions, and creates conflict records for conflict results. `applyPull` applies remote changes only when the entity has no pending local operation; otherwise it creates a conflict. Advance cursor only after the page save succeeds.

- [ ] **Step 5: Run sync tests**

Run: `cd ios/BirthdayCore && swift test --filter SyncEngineTests`

Expected: empty outbox, actual encoded-byte boundaries, JSON escaping, more than 50 operations, complete multi-batch drain before pull, applied upload, conflict, retry metadata, multi-page pull, pull rollback, proactive refresh, one replay, and rebind-required cases PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Sync/SyncEngine.swift ios/BirthdayCore/Sources/BirthdayCore/Data/BirthdayStore.swift ios/BirthdayCore/Sources/BirthdayCore/Sync/DeviceCredentialStore.swift ios/BirthdayCore/Tests/BirthdayCoreTests/SyncEngineTests.swift
git commit -m "feat(ios): 实现增量同步与令牌刷新"
```

---

### Task 6: Persist and Resolve Sync Conflicts

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Data/SyncConflictEntity.swift`
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Sync/ConflictResolver.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/ConflictResolverTests.swift`
- Create: `ios/BirthdayMobile/Features/Conflicts/ConflictListView.swift`
- Modify: `ios/BirthdayMobile/App/AppModel.swift`
- Modify: `ios/BirthdayMobile/App/BirthdayMobileApp.swift`

**Interfaces:**
- Consumes: local and remote `BirthdayRecord` snapshots
- Produces: `ConflictResolver.keepLocal(id:)`, `useRemote(id:)`, conflict badge and UI

- [ ] **Step 1: Write failing conflict-resolution tests**

```swift
import Foundation
import Testing
@testable import BirthdayCore

@Test func keepLocalCreatesFreshOperationOnRemoteVersion() async throws {
    let fixture = try makeConflictFixture(localVersion: 3, remoteVersion: 5)
    try await ConflictResolver(store: fixture.store).keepLocal(id: fixture.birthdayId)
    let operations = await fixture.store.pendingOperations()
    let operation = try #require(operations.last)
    #expect(operation.operationId != fixture.operationId)
    #expect(!operations.contains { $0.operationId == fixture.operationId })
    #expect(operation.entityId == fixture.birthdayId)
    #expect(operation.baseVersion == 5)
    #expect(operation.operationType == "upsert")
    let payload = try MobileJSON.decoder.decode(BirthdayPayloadDTO.self, from: operation.payloadJSON)
    let currentLocal = try #require((await fixture.store.activeBirthdays()).first)
    #expect(payload == BirthdayPayloadDTO(record: currentLocal))
    #expect(await fixture.store.conflicts().isEmpty)
}

@Test func useRemoteReplacesLocalAndClearsPendingOperation() async throws {
    let fixture = try makeConflictFixture(localVersion: 3, remoteVersion: 5)
    try await ConflictResolver(store: fixture.store).useRemote(id: fixture.birthdayId)
    #expect(await fixture.store.activeBirthdays().first?.version == 5)
    #expect(await fixture.store.pendingOperations().isEmpty)
}
```

- [ ] **Step 2: Implement conflict persistence**

```swift
@Model
public final class SyncConflictEntity {
    @Attribute(.unique) public var id: UUID
    public var birthdayId: UUID
    public var localJSON: Data
    public var remoteJSON: Data
    public var operationId: UUID
    public var createdAt: Date
    public var kindRaw: String

    public init(id: UUID, birthdayId: UUID, localJSON: Data, remoteJSON: Data, operationId: UUID, createdAt: Date, kindRaw: String) {
        self.id = id; self.birthdayId = birthdayId; self.localJSON = localJSON; self.remoteJSON = remoteJSON
        self.operationId = operationId; self.createdAt = createdAt; self.kindRaw = kindRaw
    }
}
```

`kindRaw` is `editEdit` or `deleteEdit`. Persist complete JSON snapshots so neither side depends on a later network call.

Add this deterministic helper to `SyncTestFixtures.swift`. It creates a four-entity in-memory schema, inserts the local row, blocked outbox operation, and both encoded conflict snapshots through a `ModelContext`, saves once, then returns `ConflictFixture(store:birthdayId:)`:

```swift
struct ConflictFixture {
    let store: BirthdayStore
    let birthdayId: UUID
    let operationId: UUID
}

func makeConflictFixture(localVersion: Int64, remoteVersion: Int64) throws -> ConflictFixture {
    let container = try ModelContainer(
        for: BirthdayEntity.self, SyncOperationEntity.self, SyncMetadataEntity.self, SyncConflictEntity.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = ModelContext(container)
    let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let operationId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let draft = BirthdayDraft(name: "妈妈", lunarBirthday: .init(month: 8, day: 15, isLeapMonth: false), reminder: .defaults)
    let entity = BirthdayEntity(id: id, draft: draft, nextSolarDate: now.addingTimeInterval(86_400), now: now)
    entity.version = localVersion
    entity.syncStateRaw = SyncState.conflict.rawValue
    let local = BirthdayRecord(id: id, name: "妈妈", lunarBirthday: draft.lunarBirthday, reminder: draft.reminder, nextSolarDate: entity.nextSolarDate, version: localVersion, createdAt: now, updatedAt: now, deletedAt: nil, syncState: .conflict)
    var remote = local
    remote.version = remoteVersion
    remote.updatedAt = now.addingTimeInterval(60)
    remote.syncState = .synced
    let operation = SyncOperationEntity(operationId: operationId, entityId: id, operationType: "upsert", baseVersion: localVersion, payloadJSON: try MobileJSON.encoder.encode(BirthdayPayloadDTO(record: local)), createdAt: now, attemptCount: 0, nextRetryAt: nil, lastErrorCategory: nil)
    let conflict = SyncConflictEntity(id: UUID(), birthdayId: id, localJSON: try MobileJSON.encoder.encode(local), remoteJSON: try MobileJSON.encoder.encode(remote), operationId: operationId, createdAt: now, kindRaw: "editEdit")
    context.insert(entity); context.insert(operation); context.insert(conflict)
    try context.save()
    return ConflictFixture(store: BirthdayStore(modelContainer: container), birthdayId: id, operationId: operationId)
}
```

Update the app composition root so `SyncConflictEntity` joins the production and UI-test `ModelContainer` schemas.

- [ ] **Step 3: Implement the two explicit resolutions**

`keepLocal` decodes both snapshots, removes (or terminally marks so it is never submitted again) the old conflict-producing outbox operation, and creates a brand-new operation in the same save. The new operation uses a new `operationId`, the same birthday `entityId`, the remote record's version as `baseVersion`, and an `upsert` payload freshly encoded from the complete current local record. It then marks the birthday pending and deletes the conflict. Reusing the old operation ID is forbidden: the server has already persisted that ID's conflict response and its replay-isolation contract would return the stored result instead of applying a rebased edit. For delete/edit “恢复并保留编辑”, the fresh full local payload is likewise an `upsert` against the remote tombstone version.

The keep-local tests must assert the old ID is absent or terminal, the new ID differs, the new base equals the remote version, the full payload equals the current local record, and the new operation can be submitted under the server contract's `(deviceId, operationId, entityId, baseVersion)` replay isolation. `useRemote` replaces all local fields with the remote record, removes the blocked outbox operation, marks synced or removes from active list if remote is a tombstone, and deletes the conflict in one save.

- [ ] **Step 4: Implement conflict UI**

`ConflictListView` lists the person's name, local updated time, cloud updated time, and changed values. It presents two destructive-aware buttons: “保留本机版本” and “使用云端版本”. Delete/edit conflicts rename the first action to “恢复并保留编辑” and the second to “确认删除”. The screen never resolves a conflict on row tap or swipe.

- [ ] **Step 5: Run tests and build**

Run: `cd ios/BirthdayCore && swift test --filter ConflictResolverTests`

Expected: edit/edit and delete/edit cases for both choices PASS.

Run: `cd ios && xcodegen generate && xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Data/SyncConflictEntity.swift ios/BirthdayCore/Sources/BirthdayCore/Sync/ConflictResolver.swift ios/BirthdayCore/Tests/BirthdayCoreTests/ConflictResolverTests.swift ios/BirthdayCore/Tests/BirthdayCoreTests/SyncTestFixtures.swift ios/BirthdayMobile/Features/Conflicts ios/BirthdayMobile/App/AppModel.swift ios/BirthdayMobile/App/BirthdayMobileApp.swift
git commit -m "feat(ios): 增加同步冲突保留与选择"
```

---

### Task 7: Coordinate Foreground, Network, Background, and Notification Refresh

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Sync/SyncTriggerGate.swift`
- Create: `ios/BirthdayMobile/Sync/SyncCoordinator.swift`
- Create: `ios/BirthdayCore/Tests/BirthdayCoreTests/SyncTriggerTests.swift`
- Modify: `ios/BirthdayMobile/App/BirthdayMobileApp.swift`
- Modify: `ios/BirthdayMobile/App/AppModel.swift`
- Modify: `ios/BirthdayMobile/Info.plist`

**Interfaces:**
- Consumes: `SyncEngine`, `NWPathMonitor`, `BGTaskScheduler`, `ReminderPlanner`, `NotificationScheduling`
- Produces: serialized `SyncCoordinator.request(_:)`; post-sync notification rebuild

- [ ] **Step 1: Write failing trigger coalescing test**

```swift
import Testing
@testable import BirthdayCore

@Test func triggerGateCoalescesConcurrentRequests() async {
    let gate = SyncTriggerGate()
    #expect(await gate.begin() == true)
    #expect(await gate.begin() == false)
    await gate.end()
    #expect(await gate.begin() == true)
}
```

- [ ] **Step 2: Implement the actor gate**

```swift
public actor SyncTriggerGate {
    private var running = false
    public init() {}
    public func begin() -> Bool {
        guard !running else { return false }
        running = true
        return true
    }
    public func end() { running = false }
}
```

- [ ] **Step 3: Implement coordinator order and triggers**

`SyncCoordinator.request(_:)` must:

1. Return immediately if unbound or gate denies concurrent run.
2. Call `SyncEngine.syncNow()`.
3. Reload active records from `BirthdayStore`.
4. Build a `ReminderPlan` with current time zone.
5. Apply system notifications.
6. Publish sync summary and notification health to `AppModel`.
7. End the gate in `defer`, including failures.

Trigger reasons are `.appLaunch`, `.foreground`, `.networkRestored`, `.localMutation`, `.manual`, and `.backgroundRefresh`.

- [ ] **Step 4: Register opportunistic background refresh**

At app launch register `top.qisw.birthday.refresh`. Schedule one `BGAppRefreshTaskRequest` with `earliestBeginDate = Date().addingTimeInterval(6 * 60 * 60)`. In the handler, immediately schedule the next request, run coordinator with `.backgroundRefresh`, honor cancellation, and call `setTaskCompleted(success:)`. Do not describe its time as guaranteed in UI or logs.

- [ ] **Step 5: Connect scene and network events**

When scene phase becomes active, request `.foreground`; when `NWPathMonitor` transitions from unsatisfied to satisfied, request `.networkRestored`. Local saves/deletes call `.localMutation` after the SwiftData transaction succeeds. Manual refresh is the only trigger that displays a spinner longer than the navigation bar refresh control.

- [ ] **Step 6: Run tests and build**

Run: `cd ios/BirthdayCore && swift test --filter SyncTriggerTests`

Expected: coalescing tests PASS.

Run: `cd ios && xcodegen generate && xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: build succeeds with BackgroundTasks and Network linked.

- [ ] **Step 7: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Sync/SyncTriggerGate.swift ios/BirthdayCore/Tests/BirthdayCoreTests/SyncTriggerTests.swift ios/BirthdayMobile/Sync ios/BirthdayMobile/App ios/BirthdayMobile/Info.plist
git commit -m "feat(ios): 协调前台后台与网络同步"
```

---

### Task 8: Finish Sync Settings and Device Management

**Files:**
- Create: `ios/BirthdayCore/Sources/BirthdayCore/Sync/DeviceManagementService.swift`
- Create: `ios/BirthdayMobile/Features/Settings/SyncSettingsView.swift`
- Modify: `ios/BirthdayMobile/Features/Settings/SettingsView.swift`
- Modify: `ios/BirthdayMobile/App/AppModel.swift`

**Interfaces:**
- Consumes: `MobileAPI.devices`, `revoke`, `SyncCoordinator`, `DeviceCredentialStore`
- Produces: visible sync boundary, manual sync, rebind, revoke, unlink-without-data-loss

- [ ] **Step 1: Add exact state presentation cases**

`AppModel.SyncPresentation` must be:

```swift
enum SyncPresentation: Equatable {
    case localOnly
    case idle(lastSuccess: Date?)
    case syncing
    case offline(pendingCount: Int)
    case failed(message: String, pendingCount: Int)
    case rebindRequired(pendingCount: Int)
    case conflicts(count: Int)
}
```

- [ ] **Step 2: Implement settings rows and copy**

`SyncSettingsView` shows:

- “仅本地使用” when unbound, with “绑定服务器” action.
- “上次同步” date and pending count when bound.
- “离线使用，稍后同步” for network absence.
- “需要重新绑定，同步已暂停；本地数据仍可使用” for auth loss.
- conflict count linking to `ConflictListView`.
- manual “立即同步”.
- device list with current device badge and explicit revoke confirmation.
- “停止同步” first revokes the current device when reachable, clears Keychain, and leaves SwiftData untouched. If revoke is unreachable, first show “服务器可能仍保留此设备，可在重新绑定后撤销”; only the user's second explicit “仍要停止本机同步” confirmation clears Keychain locally.

- [ ] **Step 3: Implement the device-management boundary and add tests**

Create `DeviceManagementService` with these explicit outcomes:

```swift
public enum DeviceManagementError: Error, Equatable { case confirmationMismatch }
public enum UnlinkOutcome: Equatable, Sendable {
    case unlinked
    case needsLocalConfirmation(message: String)
}

public struct DeviceManagementService: Sendable {
    public let api: any MobileAPI
    public let credentials: DeviceCredentialStore

    public func revokeOther(_ device: MobileDevice, typedUsername: String, expectedUsername: String, accessToken: String) async throws {
        guard typedUsername == expectedUsername else { throw DeviceManagementError.confirmationMismatch }
        try await api.revoke(deviceId: device.deviceId, accessToken: accessToken)
    }

    public func beginUnlinkCurrent(_ current: DeviceCredentials) async -> UnlinkOutcome {
        do {
            try await api.revoke(deviceId: current.deviceId, accessToken: current.accessToken)
            try credentials.clear()
            return .unlinked
        } catch {
            return .needsLocalConfirmation(message: "服务器可能仍保留此设备，可在重新绑定后撤销")
        }
    }

    public func confirmLocalUnlink() throws { try credentials.clear() }
}
```

Create `ios/BirthdayCore/Tests/BirthdayCoreTests/DeviceManagementTests.swift` and assert: revoking another device rejects a non-matching typed username; successful unlink clears credentials but the store's active record count is unchanged; an unreachable revoke preserves credentials until the warning is returned and `confirmLocalUnlink()` is called.

- [ ] **Step 4: Run tests and build**

Run: `cd ios/BirthdayCore && swift test --filter DeviceManagementTests`

Expected: device and unlink cases PASS.

Run: `cd ios && xcodegen generate && xcodebuild -project BirthdayMobile.xcodeproj -scheme BirthdayMobile -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`

Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add ios/BirthdayCore/Sources/BirthdayCore/Sync/DeviceManagementService.swift ios/BirthdayMobile/Features/Settings ios/BirthdayMobile/App/AppModel.swift ios/BirthdayCore/Tests/BirthdayCoreTests/DeviceManagementTests.swift
git commit -m "feat(ios): 完成同步状态与设备管理"
```

---

### Task 9: Run End-to-End Contract Verification

**Files:**
- Create: `tests/integration/mobileSyncE2E.test.js`
- Create: `ios/QA/SYNC_ACCEPTANCE.md`
- Modify: `package.json`

**Interfaces:**
- Consumes: production router factories and a disposable MySQL database
- Produces: reproducible server-to-iOS DTO fixtures and end-to-end acceptance evidence

- [ ] **Step 1: Add an integration test script that requires an explicit test database**

Add:

```json
{
  "scripts": {
    "test:integration:mobile": "MOBILE_SYNC_TEST_DB_REQUIRED=1 node --test tests/integration/mobileSyncE2E.test.js"
  }
}
```

The test must refuse to run unless the database name ends with `_test`; never point it at the production database.

- [ ] **Step 2: Implement the exact end-to-end scenario**

`mobileSyncE2E.test.js` must:

1. Apply clean schema plus mobile migration to the disposable database.
2. Log in and bind device A.
3. Create a birthday offline-shaped payload through mobile push.
4. Replay the same operation and assert one database row and identical response.
5. Pull from cursor 0 and assert the birthday appears.
6. Bind device B and update the record.
7. Push stale device-A baseVersion and assert conflict without overwrite.
8. Soft-delete on device B and assert snapshot includes a tombstone and email reminder is absent.
9. Run lunar contract fixtures through the server helper.
10. Drop only the disposable test database in teardown.

- [ ] **Step 3: Add the manual two-device acceptance checklist**

`ios/QA/SYNC_ACCEPTANCE.md` contains:

```markdown
- [ ] 首次导入条数与网页当前生日条数一致
- [ ] 飞行模式新增后立即可见，并显示待同步
- [ ] 恢复网络后自动同步，网页可见同一 UUID
- [ ] 第二台设备拉取到变更并重排本地通知
- [ ] 两台设备同时编辑同一记录时出现冲突，不静默覆盖
- [ ] 保留本机与使用云端两条解决路径均验证
- [ ] 删除与离线编辑冲突可以恢复或确认删除
- [ ] 访问令牌过期自动刷新一次
- [ ] 撤销设备后该设备同步收到认证失效，本地数据仍可用
- [ ] 服务器停机期间本地查看、编辑、Face ID 和通知正常
```

- [ ] **Step 4: Run automated suites**

Run: `npm test`

Expected: all unit and route tests PASS.

Run against a disposable database only: `npm run test:integration:mobile`

Expected: end-to-end scenario PASS.

Run: `cd ios/BirthdayCore && swift test`

Expected: all Swift tests PASS.

- [ ] **Step 5: Commit**

```bash
git add package.json package-lock.json tests/integration/mobileSyncE2E.test.js ios/QA/SYNC_ACCEPTANCE.md
git commit -m "test(sync): 覆盖双设备增量同步流程"
```

---

### Task 10: Prepare and Verify the First TestFlight Build

**Files:**
- Create: `ios/BirthdayMobile/Config/Debug.xcconfig`
- Create: `ios/BirthdayMobile/Config/Release.xcconfig`
- Create: `ios/BirthdayMobile/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `ios/QA/TESTFLIGHT_ACCEPTANCE.md`
- Modify: `ios/project.yml`
- Modify: `ios/BirthdayMobile/Info.plist`

**Interfaces:**
- Consumes: signed Apple developer team, reviewed production API URL, completed local and sync QA
- Produces: versioned archive and TestFlight-ready acceptance evidence

- [ ] **Step 1: Add environment-specific API configuration**

```xcconfig
// Debug.xcconfig
BIRTHDAY_API_BASE_URL = https:/$()/qisw.top/api/mobile
```

```xcconfig
// Release.xcconfig
BIRTHDAY_API_BASE_URL = https:/$()/qisw.top/api/mobile
```

Expose it through `Info.plist` as `BirthdayAPIBaseURL=$(BIRTHDAY_API_BASE_URL)`. `AppConfiguration` must validate HTTPS and reject a missing/invalid URL with a visible local-only state instead of crashing.

- [ ] **Step 2: Finalize XcodeGen signing and capabilities**

Set `DEVELOPMENT_TEAM` from a local, uncommitted `ios/Config/Signing.xcconfig`; add that file to `.gitignore`. Enable only Background Modes `fetch`, matching the `BGAppRefreshTaskRequest` used in Task 7. Do not add processing, remote-notification, associated-domain, contacts, photo, or location capabilities.

- [ ] **Step 3: Create the final app icon set**

Generate one 1024×1024 source icon matching the confirmed modern-air direction: teal-to-mist-blue field, a simple white calendar ring combined with a subtle lunar crescent, no text, no transparency, readable at 29 points. Export required iPhone icon sizes into `AppIcon.appiconset` and validate that `Contents.json` references every generated file.

- [ ] **Step 4: Create the TestFlight checklist**

`ios/QA/TESTFLIGHT_ACCEPTANCE.md` must include:

```markdown
- [ ] Debug and Release both build from a clean XcodeGen regeneration
- [ ] Release uses HTTPS production API URL and contains no token or password
- [ ] App icon, display name“岁时”、版本 1.0.0、构建号 1 正确
- [ ] 真机首次启动、通知说明、Face ID 和设备密码回退通过
- [ ] 真机飞行模式完整 CRUD 与重启持久化通过
- [ ] 真机提前一天、当天和维护通知通过
- [ ] 首次服务器导入数量核对通过
- [ ] 双设备冲突与解绑不删本地数据通过
- [ ] 动态字体、VoiceOver、深色模式、减少动态效果通过
- [ ] 隐私说明仅声明实际使用的数据和网络行为
```

- [ ] **Step 5: Run pre-archive verification**

Run: `cd ios/BirthdayCore && swift test`

Expected: all tests PASS.

Run: `npm test`

Expected: all server tests PASS.

Run: `cd ios && xcodegen generate`

Expected: project regeneration succeeds.

Run: `xcodebuild -project ios/BirthdayMobile.xcodeproj -scheme BirthdayMobile -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/BirthdayMobile.xcarchive archive`

Expected: `** ARCHIVE SUCCEEDED **`; inspect archive for bundle ID, version, build, icon, entitlements, and absence of development API values.

- [ ] **Step 6: Stop at the publication boundary**

Upload to TestFlight only after the user confirms the archive evidence and Apple account target. Treat upload as submitted processing, not publicly available. Do not claim TestFlight availability until App Store Connect finishes processing and the build is visible to the intended tester group.

- [ ] **Step 7: Commit**

```bash
git add .gitignore ios/project.yml ios/BirthdayMobile/Config ios/BirthdayMobile/Info.plist ios/BirthdayMobile/Assets.xcassets/AppIcon.appiconset ios/QA/TESTFLIGHT_ACCEPTANCE.md
git commit -m "chore(ios): 准备首个 TestFlight 构建"
```
