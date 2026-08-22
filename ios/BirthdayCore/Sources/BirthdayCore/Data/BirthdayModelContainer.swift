import SwiftData

public enum BirthdayModelContainer {
  public static func make(configuration: ModelConfiguration) throws -> ModelContainer {
    try ModelContainer(
      for: BirthdayEntity.self,
      SyncOperationEntity.self,
      SyncMetadataEntity.self,
      SyncConflictEntity.self,
      configurations: configuration
    )
  }
}
