import Foundation
import Testing

@testable import BirthdayCore

@Test func cloudSyncPreferenceDefaultsOnAndPreservesAnExplicitDeviceChoice() throws {
  let suiteName = "cloud-sync-preference-\(UUID().uuidString)"
  let preferences = try #require(UserDefaults(suiteName: suiteName))
  defer { preferences.removePersistentDomain(forName: suiteName) }
  let store = CloudSyncPreferenceStore(preferences: preferences)

  #expect(store.isEnabled)
  store.isEnabled = false
  #expect(!CloudSyncPreferenceStore(preferences: preferences).isEnabled)
  store.isEnabled = true
  #expect(CloudSyncPreferenceStore(preferences: preferences).isEnabled)
}

@Test func cloudAccountMarkerStoresOnlyAnIrreversibleDigestAndDetectsAccountChanges() throws {
  let secure = InMemorySecureTokenStore()
  let store = CloudAccountMarkerStore(secure: secure)

  #expect(try store.compareAndEstablish(recordName: "user-record-123") == .established)
  #expect(try store.compareAndEstablish(recordName: "user-record-123") == .matches)
  #expect(try store.compareAndEstablish(recordName: "another-user") == .changed)

  let saved = try #require(try secure.read(account: "icloud-private-account-marker"))
  #expect(saved.count == 32)
  #expect(saved.map { String(format: "%02x", $0) }.joined() ==
    "a8ec2cc7b5196282c4a147830b83d0af6af7e61798ed84d4428033f8711dfca9")
  #expect(String(data: saved, encoding: .utf8) != "user-record-123")

  try store.replaceAfterConfirmation(recordName: "another-user")
  #expect(try store.compareAndEstablish(recordName: "another-user") == .matches)
}
