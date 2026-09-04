import CloudKit
import Foundation

public struct CloudSyncPreferenceStore: @unchecked Sendable {
  private static let enabledKey = "top.qisw.birthday.icloud.sync.enabled"

  private let preferences: UserDefaults

  public init(preferences: UserDefaults = .standard) {
    self.preferences = preferences
  }

  public var isEnabled: Bool {
    get {
      guard preferences.object(forKey: Self.enabledKey) != nil else { return true }
      return preferences.bool(forKey: Self.enabledKey)
    }
    nonmutating set {
      preferences.set(newValue, forKey: Self.enabledKey)
    }
  }
}

public enum CloudAccountAvailability: Equatable, Sendable {
  case available(recordName: String)
  case noAccount
  case restricted
  case temporarilyUnavailable
  case couldNotDetermine
}

public protocol CloudAccountProviding: Sendable {
  func currentAccount() async throws -> CloudAccountAvailability
}

protocol CloudAccountSystemClient: Sendable {
  func accountStatus() async throws -> CKAccountStatus
  func userRecordID() async throws -> CKRecord.ID
}

private struct LiveCloudAccountSystemClient: CloudAccountSystemClient {
  let container: CKContainer

  func accountStatus() async throws -> CKAccountStatus {
    try await container.accountStatus()
  }

  func userRecordID() async throws -> CKRecord.ID {
    try await container.userRecordID()
  }
}

public struct SystemCloudAccountProvider: CloudAccountProviding {
  private let client: any CloudAccountSystemClient

  public init(
    containerIdentifier: String = SystemCloudSyncEngineAdapter.defaultContainerIdentifier
  ) {
    client = LiveCloudAccountSystemClient(container: CKContainer(identifier: containerIdentifier))
  }

  init(client: any CloudAccountSystemClient) {
    self.client = client
  }

  public func currentAccount() async throws -> CloudAccountAvailability {
    switch try await client.accountStatus() {
    case .available:
      return .available(recordName: try await client.userRecordID().recordName)
    case .noAccount:
      return .noAccount
    case .restricted:
      return .restricted
    case .temporarilyUnavailable:
      return .temporarilyUnavailable
    case .couldNotDetermine:
      return .couldNotDetermine
    @unknown default:
      return .couldNotDetermine
    }
  }
}

public protocol CloudSyncCoordinatorRepository: Sendable {
  func pendingCloudChangeCount() async throws -> Int
  func cloudConflictCount() async throws -> Int
  func resetCloudStateForAccountChange() async throws
  func markCloudSyncSucceeded(at date: Date) async throws
}

extension BirthdayStore: CloudSyncCoordinatorRepository {
  public func pendingCloudChangeCount() throws -> Int {
    try pendingCloudChanges(limit: .max).count
  }

  public func cloudConflictCount() throws -> Int {
    try cloudConflicts().count
  }

  public func markCloudSyncSucceeded(at date: Date) throws {
    try markCloudInitialMergeCompleted(at: date)
  }
}

public enum CloudSyncStatus: Equatable, Sendable {
  case disabled
  case unavailable
  case syncing
  case pending(count: Int)
  case synchronized(date: Date)
  case accountChangeRequiresConfirmation
  case conflicts(count: Int)
  case failed(category: CloudErrorCategory)
}

public typealias CloudSyncEngineFactory = @Sendable () async throws -> any CloudSyncEngineClient

public actor CloudSyncCoordinator {
  public private(set) var status: CloudSyncStatus

  private let preference: CloudSyncPreferenceStore
  private let accountProvider: any CloudAccountProviding
  private let accountMarkerStore: CloudAccountMarkerStore
  private let repository: any CloudSyncCoordinatorRepository
  private let engineFactory: CloudSyncEngineFactory
  private let now: @Sendable () -> Date
  private var engine: (any CloudSyncEngineClient)?
  private var nextRetryAt: Date?
  private var pendingAccountRecordName: String?

  public init(
    preference: CloudSyncPreferenceStore = CloudSyncPreferenceStore(),
    accountProvider: any CloudAccountProviding,
    accountMarkerStore: CloudAccountMarkerStore = CloudAccountMarkerStore(),
    repository: any CloudSyncCoordinatorRepository,
    engineFactory: @escaping CloudSyncEngineFactory,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.preference = preference
    self.accountProvider = accountProvider
    self.accountMarkerStore = accountMarkerStore
    self.repository = repository
    self.engineFactory = engineFactory
    self.now = now
    status = preference.isEnabled ? .unavailable : .disabled
  }

  public func start() async {
    guard preference.isEnabled else {
      status = .disabled
      return
    }
    do {
      guard try await accountAllowsSync() else { return }
      status = .syncing
      let currentEngine: any CloudSyncEngineClient
      if let engine {
        currentEngine = engine
      } else {
        let created = try await engineFactory()
        engine = created
        currentEngine = created
      }
      try await currentEngine.start()
      try await finishSuccessfulSync()
    } catch {
      recordFailure(error)
    }
  }

  public func setEnabled(_ enabled: Bool) async {
    preference.isEnabled = enabled
    guard enabled else {
      if let engine { await engine.pause() }
      status = .disabled
      return
    }
    await start()
  }

  public func requestSync() async {
    guard preference.isEnabled else {
      status = .disabled
      return
    }
    if let nextRetryAt, now() < nextRetryAt {
      status = .failed(category: .rateLimited)
      return
    }
    do {
      guard try await accountAllowsSync() else { return }
      status = .syncing
      if let engine {
        try await engine.fetch()
        try await engine.send()
      } else {
        let created = try await engineFactory()
        engine = created
        try await created.start()
      }
      try await finishSuccessfulSync()
    } catch {
      recordFailure(error)
    }
  }

  public func confirmAccountChange() async {
    guard preference.isEnabled else {
      status = .disabled
      return
    }
    do {
      guard
        case .available(let currentRecordName) = try await accountProvider.currentAccount(),
        currentRecordName == pendingAccountRecordName
      else {
        status = .unavailable
        return
      }
      if let engine { await engine.close() }
      engine = nil
      try await repository.resetCloudStateForAccountChange()
      try accountMarkerStore.replaceAfterConfirmation(recordName: currentRecordName)
      pendingAccountRecordName = nil
      nextRetryAt = nil
      await start()
    } catch {
      recordFailure(error)
    }
  }

  public func cancelAccountChange() async {
    preference.isEnabled = false
    if let engine { await engine.close() }
    engine = nil
    pendingAccountRecordName = nil
    nextRetryAt = nil
    status = .disabled
  }

  private func accountAllowsSync() async throws -> Bool {
    switch try await accountProvider.currentAccount() {
    case .available(let recordName):
      switch try accountMarkerStore.compareAndEstablish(recordName: recordName) {
      case .established, .matches:
        pendingAccountRecordName = nil
        return true
      case .changed:
        if let engine { await engine.pause() }
        pendingAccountRecordName = recordName
        status = .accountChangeRequiresConfirmation
        return false
      }
    case .noAccount, .couldNotDetermine:
      if let engine { await engine.pause() }
      status = .unavailable
      return false
    case .restricted, .temporarilyUnavailable:
      if let engine { await engine.pause() }
      status = .failed(category: .accountRestricted)
      return false
    }
  }

  private func finishSuccessfulSync() async throws {
    let completedAt = now()
    nextRetryAt = nil
    try await repository.markCloudSyncSucceeded(at: completedAt)
    let conflicts = try await repository.cloudConflictCount()
    if conflicts > 0 {
      status = .conflicts(count: conflicts)
      return
    }
    let pending = try await repository.pendingCloudChangeCount()
    status = pending > 0 ? .pending(count: pending) : .synchronized(date: completedAt)
  }

  private func recordFailure(_ error: Error) {
    let category = CloudErrorClassifier.classify(error)
    if category == .rateLimited {
      let retryAfter = (error as? CKError)?
        .userInfo[CKErrorRetryAfterKey] as? TimeInterval ?? 60
      nextRetryAt = now().addingTimeInterval(max(1, retryAfter))
    } else {
      nextRetryAt = nil
    }
    status = category == .notSignedIn ? .unavailable : .failed(category: category)
  }
}
