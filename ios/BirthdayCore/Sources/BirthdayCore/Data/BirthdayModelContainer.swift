import SwiftData

public enum BirthdaySchemaV1: VersionedSchema {
  public static let versionIdentifier = Schema.Version(1, 0, 0)
  public static let models: [any PersistentModel.Type] = [
    BirthdaySchemaV1.BirthdayEntity.self,
    BirthdaySchemaV1.SyncOperationEntity.self,
    BirthdaySchemaV1.SyncMetadataEntity.self,
  ]
}

public enum BirthdaySchemaV2: VersionedSchema {
  public static let versionIdentifier = Schema.Version(2, 0, 0)
  public static let models: [any PersistentModel.Type] = [
    BirthdaySchemaV2.BirthdayEntity.self,
    BirthdaySchemaV2.SyncOperationEntity.self,
    BirthdaySchemaV2.SyncMetadataEntity.self,
    BirthdaySchemaV2.SyncConflictEntity.self,
  ]
}

public enum BirthdaySchemaMigrationPlan: SchemaMigrationPlan {
  public static let schemas: [any VersionedSchema.Type] = [
    BirthdaySchemaV1.self,
    BirthdaySchemaV2.self,
    BirthdaySchemaV3.self,
  ]

  public static let stages: [MigrationStage] = [
    .lightweight(fromVersion: BirthdaySchemaV1.self, toVersion: BirthdaySchemaV2.self),
    .lightweight(fromVersion: BirthdaySchemaV2.self, toVersion: BirthdaySchemaV3.self),
  ]
}

public enum BirthdayModelContainer {
  public static func make(configuration: ModelConfiguration) throws -> ModelContainer {
    try ModelContainer(
      for: Schema(versionedSchema: BirthdaySchemaV3.self),
      migrationPlan: BirthdaySchemaMigrationPlan.self,
      configurations: configuration
    )
  }
}
