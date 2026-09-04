import BirthdayCore
import SwiftUI

struct ConflictListView: View {
  @Bindable var model: AppModel

  var body: some View {
    Group {
      if model.isLoading || model.loadState == .idle {
        ProgressView("正在读取同步冲突")
          .tint(ModernAirTheme.tide)
      } else if !model.hasSyncConflicts {
        emptyState
      } else {
        conflictList
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(ModernAirTheme.mist.ignoresSafeArea())
    .navigationTitle("同步冲突")
  }

  private var conflictList: some View {
    List {
      if let message = model.conflictErrorMessage {
        Section {
          Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }

      ForEach(model.conflicts) { conflict in
        ConflictCard(
          conflict: conflict,
          isResolving: model.isResolvingConflict(conflict.id),
          isAnyResolutionInProgress: model.resolvingConflictID != nil,
          keepLocal: {
            Task { await model.resolveConflictKeepingLocal(id: conflict.id) }
          },
          useRemote: {
            Task { await model.resolveConflictUsingRemote(id: conflict.id) }
          }
        )
      }

      ForEach(model.cloudConflicts, id: \.entityID) { conflict in
        CloudConflictCard(
          conflict: conflict,
          isResolving: model.isResolvingConflict(conflict.entityID),
          isAnyResolutionInProgress: model.resolvingConflictID != nil,
          keepLocal: {
            Task { await model.resolveCloudConflictKeepingLocal(id: conflict.entityID) }
          },
          useICloud: {
            Task { await model.resolveCloudConflictUsingICloud(id: conflict.entityID) }
          }
        )
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .refreshable { await model.reload() }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(
        model.conflictErrorMessage == nil ? "没有待处理冲突" : "无法读取同步冲突",
        systemImage: model.conflictErrorMessage == nil
          ? "checkmark.circle" : "externaldrive.badge.exclamationmark"
      )
    } description: {
      Text(model.conflictErrorMessage ?? "本机资料与云端资料当前没有需要手动选择的版本。")
    } actions: {
      Button("重新读取") {
        Task { await model.reload() }
      }
      .buttonStyle(.borderedProminent)
      .tint(ModernAirTheme.tide)
      .frame(minHeight: 44)
    }
  }
}

enum CloudConflictPresentation {
  static func changedValues(
    local: CloudBirthdaySnapshot,
    iCloud: CloudBirthdaySnapshot
  ) -> [String] {
    var values: [String] = []
    appendChange("姓名", local: local.name, remote: iCloud.name, to: &values)
    appendChange(
      "农历生日",
      local: lunarText(local),
      remote: lunarText(iCloud),
      to: &values
    )
    appendChange(
      "提醒时间",
      local: timeText(local.reminderTimeMinutes),
      remote: timeText(iCloud.reminderTimeMinutes),
      to: &values
    )
    appendChange(
      "通知",
      local: notificationText(local),
      remote: notificationText(iCloud),
      to: &values
    )
    appendChange(
      "状态",
      local: local.deletedAt == nil ? "保留" : "已删除",
      remote: iCloud.deletedAt == nil ? "保留" : "已删除",
      to: &values
    )
    return values.isEmpty ? ["生日内容相同，仅同步状态需要确认。"] : values
  }

  private static func appendChange(
    _ label: String,
    local: String,
    remote: String,
    to values: inout [String]
  ) {
    guard local != remote else { return }
    values.append("\(label)：本机“\(local)” / iCloud“\(remote)”")
  }

  private static func lunarText(_ snapshot: CloudBirthdaySnapshot) -> String {
    "\(snapshot.isLeapMonth ? "闰" : "")\(snapshot.lunarMonth)月\(snapshot.lunarDay)日"
  }

  private static func timeText(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
  }

  private static func notificationText(_ snapshot: CloudBirthdaySnapshot) -> String {
    switch (snapshot.notifyDayBefore, snapshot.notifySameDay) {
    case (true, true): "提前一天、生日当天"
    case (true, false): "提前一天"
    case (false, true): "生日当天"
    case (false, false): "关闭"
    }
  }
}

private struct CloudConflictCard: View {
  let conflict: CloudConflictRecord
  let isResolving: Bool
  let isAnyResolutionInProgress: Bool
  let keepLocal: () -> Void
  let useICloud: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text(conflict.local.name)
          .font(.headline)
          .foregroundStyle(ModernAirTheme.ink)
        Label(
          "本机更新：\(conflict.local.updatedAt.formatted(date: .abbreviated, time: .shortened))",
          systemImage: "internaldrive"
        )
        Label(
          "iCloud 更新：\(conflict.iCloud.updatedAt.formatted(date: .abbreviated, time: .shortened))",
          systemImage: "icloud"
        )
      }
      .font(.caption)
      .foregroundStyle(ModernAirTheme.secondaryInk)

      VStack(alignment: .leading, spacing: 8) {
        Text("不同内容")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(ModernAirTheme.ink)
        ForEach(changedValues, id: \.self) { value in
          Text(value)
            .font(.caption)
            .foregroundStyle(ModernAirTheme.secondaryInk)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      HStack(spacing: 10) {
        Button(localActionTitle, action: keepLocal)
          .buttonStyle(.borderedProminent)
          .tint(ModernAirTheme.tide)
          .accessibilityIdentifier("keepLocalCloudConflictButton-\(conflict.entityID.uuidString)")

        Button(iCloudActionTitle, role: .destructive, action: useICloud)
          .buttonStyle(.bordered)
          .accessibilityIdentifier("useICloudConflictButton-\(conflict.entityID.uuidString)")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .disabled(isAnyResolutionInProgress)

      if isResolving {
        ProgressView("正在保存选择")
          .font(.caption)
          .foregroundStyle(ModernAirTheme.secondaryInk)
      }
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
  }

  private var localActionTitle: String {
    conflict.kind == .localDeleteRemoteEdit ? "保留本机删除" : "保留本机版本"
  }

  private var iCloudActionTitle: String {
    conflict.kind == .localEditRemoteDelete ? "使用 iCloud 删除" : "使用 iCloud 版本"
  }

  private var changedValues: [String] {
    CloudConflictPresentation.changedValues(local: conflict.local, iCloud: conflict.iCloud)
  }
}

private struct ConflictCard: View {
  let conflict: ResolvableSyncConflict
  let isResolving: Bool
  let isAnyResolutionInProgress: Bool
  let keepLocal: () -> Void
  let useRemote: () -> Void

  private var isDeleteEdit: Bool {
    conflict.kind == .deleteEdit
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        Text(conflict.local.name)
          .font(.headline)
          .foregroundStyle(ModernAirTheme.ink)

        Label(
          "本机更新：\(conflict.local.updatedAt.formatted(date: .abbreviated, time: .shortened))",
          systemImage: "iphone"
        )
        Label(
          "云端更新：\(conflict.remote.updatedAt.formatted(date: .abbreviated, time: .shortened))",
          systemImage: "icloud"
        )
      }
      .font(.caption)
      .foregroundStyle(ModernAirTheme.secondaryInk)

      VStack(alignment: .leading, spacing: 8) {
        Text("不同内容")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(ModernAirTheme.ink)

        ForEach(changedValues, id: \.self) { value in
          Text(value)
            .font(.caption)
            .foregroundStyle(ModernAirTheme.secondaryInk)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }

      HStack(spacing: 10) {
        Button(isDeleteEdit ? "恢复并保留编辑" : "保留本机版本", action: keepLocal)
          .buttonStyle(.borderedProminent)
          .tint(ModernAirTheme.tide)
          .accessibilityIdentifier("keepLocalConflictButton-\(conflict.id.uuidString)")

        Button(isDeleteEdit ? "确认删除" : "使用云端版本", role: .destructive, action: useRemote)
          .buttonStyle(.bordered)
          .accessibilityIdentifier("useRemoteConflictButton-\(conflict.id.uuidString)")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .disabled(isAnyResolutionInProgress)

      if isResolving {
        ProgressView("正在保存选择")
          .font(.caption)
          .foregroundStyle(ModernAirTheme.secondaryInk)
      }
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .contain)
  }

  private var changedValues: [String] {
    var values: [String] = []
    appendChange("姓名", local: conflict.local.name, remote: conflict.remote.name, to: &values)
    appendChange(
      "农历生日",
      local: lunarText(conflict.local),
      remote: lunarText(conflict.remote),
      to: &values
    )
    appendChange(
      "提醒时间",
      local: timeText(conflict.local.reminderTimeMinutes),
      remote: timeText(conflict.remote.reminderTimeMinutes),
      to: &values
    )
    appendChange(
      "通知",
      local: notificationText(conflict.local),
      remote: notificationText(conflict.remote),
      to: &values
    )
    appendChange(
      "邮件提醒",
      local: emailText(conflict.local),
      remote: emailText(conflict.remote),
      to: &values
    )
    appendChange(
      "状态",
      local: conflict.local.deletedAt == nil ? "保留" : "已删除",
      remote: conflict.remote.deletedAt == nil ? "保留" : "已删除",
      to: &values
    )
    appendChange(
      "版本",
      local: "v\(conflict.local.version)",
      remote: "v\(conflict.remote.version)",
      to: &values
    )
    return values.isEmpty ? ["完整资料相同，仅同步状态需要确认。"] : values
  }

  private func appendChange(
    _ label: String,
    local: String,
    remote: String,
    to values: inout [String]
  ) {
    guard local != remote else { return }
    values.append("\(label)：本机“\(local)” / 云端“\(remote)”")
  }

  private func lunarText(_ record: APIBirthday) -> String {
    "\(record.isLeapMonth ? "闰" : "")\(record.lunarMonth)月\(record.lunarDay)日"
  }

  private func timeText(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
  }

  private func notificationText(_ record: APIBirthday) -> String {
    switch (record.notifyDayBefore, record.notifySameDay) {
    case (true, true): "提前一天、生日当天"
    case (true, false): "提前一天"
    case (false, true): "生日当天"
    case (false, false): "关闭"
    }
  }

  private func emailText(_ record: APIBirthday) -> String {
    guard record.emailEnabled else { return "关闭" }
    return "开启（\(record.emailAddress)，\(record.emailMessage)）"
  }
}
