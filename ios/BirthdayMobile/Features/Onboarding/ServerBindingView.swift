import BirthdayCore
import SwiftUI
import UIKit

struct ServerBindingView: View {
  @Bindable var model: AppModel
  let onSkip: () -> Void
  let onBound: () -> Void
  let presentsSnapshotPreview: Bool

  @State private var username = ""
  @State private var password = ""
  @State private var deviceName: String
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case username
    case password
    case deviceName
  }

  init(
    model: AppModel,
    defaultDeviceName: String = UIDevice.current.name,
    presentsSnapshotPreview: Bool = true,
    onSkip: @escaping () -> Void,
    onBound: @escaping () -> Void
  ) {
    self.model = model
    self.onSkip = onSkip
    self.onBound = onBound
    self.presentsSnapshotPreview = presentsSnapshotPreview
    _deviceName = State(initialValue: defaultDeviceName)
  }

  var body: some View {
    VStack(spacing: 22) {
      header
      fields

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.circle.fill")
          .font(.subheadline)
          .foregroundStyle(ModernAirTheme.ink)
          .fixedSize(horizontal: false, vertical: true)
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 18))
          .accessibilityElement(children: .combine)
          .accessibilityLabel("绑定失败，\(errorMessage)")
      }

      VStack(spacing: 12) {
        Button(action: bind) {
          HStack(spacing: 9) {
            if isBinding {
              ProgressView()
                .tint(.white)
                .accessibilityHidden(true)
            } else {
              Image(systemName: "arrow.triangle.2.circlepath.icloud.fill")
                .accessibilityHidden(true)
            }
            Text(
              isBinding
                ? "正在安全绑定"
                : (presentsSnapshotPreview ? "绑定并查看预览" : "重新绑定并恢复同步")
            )
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(ModernAirTheme.tide)
        .disabled(isBinding)
        .accessibilityIdentifier("bindServerButton")
        .accessibilityHint(
          presentsSnapshotPreview
            ? "使用当前填写的账号绑定此设备，成功后查看首次导入预览"
            : "使用当前填写的账号重新绑定此设备并恢复同步"
        )

        Button("暂不绑定", action: skip)
          .buttonStyle(.bordered)
          .controlSize(.large)
          .tint(ModernAirTheme.tide)
          .frame(maxWidth: .infinity, minHeight: 44)
          .disabled(isBinding)
          .accessibilityIdentifier("skipServerBindingButton")
          .accessibilityHint("跳过服务器连接，直接使用本地生日功能")
      }
    }
    .onDisappear {
      clearSensitiveInput()
    }
  }

  private var header: some View {
    VStack(spacing: 18) {
      Image(systemName: "icloud.and.arrow.down.fill")
        .font(.system(size: 42, weight: .medium))
        .foregroundStyle(ModernAirTheme.dusk)
        .frame(width: 86, height: 86)
        .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 26))
        .accessibilityHidden(true)

      VStack(spacing: 10) {
        Text(presentsSnapshotPreview ? "连接服务器（可选）" : "重新绑定服务器")
          .font(.system(.largeTitle, design: .rounded, weight: .bold))
          .multilineTextAlignment(.center)
          .foregroundStyle(ModernAirTheme.ink)

        Text(
          presentsSnapshotPreview
            ? "绑定后会先进入导入预览；确认前不会改动本机生日资料，也不会推进同步游标。跳过后仍可完整离线使用。"
            : "重新绑定只更新这台设备的同步凭据并恢复同步，不会删除或重新导入本机生日资料。"
        )
        .font(.body)
        .multilineTextAlignment(.center)
        .foregroundStyle(ModernAirTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var fields: some View {
    VStack(spacing: 16) {
      bindingField(title: "管理员用户名", systemImage: "person.fill") {
        TextField("请输入用户名", text: $username)
          .textContentType(.username)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($focusedField, equals: .username)
          .accessibilityLabel("管理员用户名")
          .accessibilityIdentifier("serverUsernameField")
      }

      bindingField(title: "管理员密码", systemImage: "key.fill") {
        SecureField("请输入密码", text: $password)
          .textContentType(.password)
          .focused($focusedField, equals: .password)
          .accessibilityLabel("管理员密码")
          .accessibilityIdentifier("serverPasswordField")
      }

      bindingField(title: "设备名称", systemImage: "iphone") {
        TextField("用于识别这台设备", text: $deviceName)
          .textContentType(.name)
          .focused($focusedField, equals: .deviceName)
          .accessibilityLabel("设备名称")
          .accessibilityIdentifier("serverDeviceNameField")
      }
    }
    .textFieldStyle(.roundedBorder)
    .disabled(isBinding)
    .padding(18)
    .modernAirSurface(radius: 24)
  }

  private func bindingField<Content: View>(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(ModernAirTheme.secondaryInk)
      content()
        .frame(minHeight: 44)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var isBinding: Bool {
    model.serverBindingState == .binding
  }

  private var errorMessage: String? {
    guard case .failed(let message) = model.serverBindingState else { return nil }
    return message
  }

  private func bind() {
    guard !isBinding else { return }
    focusedField = nil

    Task { @MainActor in
      let succeeded = await model.bindServer(
        username: username,
        password: password,
        deviceName: deviceName
      )
      clearSensitiveInput()
      if succeeded {
        onBound()
      }
    }
  }

  private func skip() {
    clearSensitiveInput()
    onSkip()
  }

  private func clearSensitiveInput() {
    password = ""
    focusedField = nil
  }
}

struct SnapshotImportPreviewView: View {
  @Bindable var model: AppModel
  let onContinueLocal: () -> Void

  var body: some View {
    VStack(spacing: 22) {
      header

      switch model.snapshotImportState {
      case .idle, .loading:
        ProgressView("正在读取服务器快照")
          .tint(ModernAirTheme.tide)
          .frame(maxWidth: .infinity, minHeight: 120)
          .modernAirSurface(radius: 24)
      case .failed:
        failureContent
      case .refreshFailed:
        refreshFailureContent
      case .ready, .importing:
        if let preview = model.snapshotImportPreview {
          previewContent(preview)
        }
      case .completed:
        ProgressView("正在打开月历")
          .tint(ModernAirTheme.tide)
      }
    }
    .task {
      if model.snapshotImportState == .idle {
        await model.loadInitialSnapshotPreview()
      }
    }
  }

  private var header: some View {
    VStack(spacing: 16) {
      Image(systemName: "tray.and.arrow.down.fill")
        .font(.system(size: 42, weight: .medium))
        .foregroundStyle(ModernAirTheme.dusk)
        .frame(width: 86, height: 86)
        .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 26))
        .accessibilityHidden(true)

      Text("首次导入预览")
        .font(.system(.largeTitle, design: .rounded, weight: .bold))
        .multilineTextAlignment(.center)
        .foregroundStyle(ModernAirTheme.ink)

      Text("先核对可能重复的生日。在你为每一项做出选择前，不会写入本机资料或推进同步游标。")
        .font(.body)
        .multilineTextAlignment(.center)
        .foregroundStyle(ModernAirTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var failureContent: some View {
    VStack(spacing: 16) {
      Label(
        model.snapshotImportErrorMessage ?? "暂时无法准备导入预览，本机资料未改变。",
        systemImage: "exclamationmark.icloud.fill"
      )
      .font(.subheadline)
      .foregroundStyle(ModernAirTheme.ink)
      .fixedSize(horizontal: false, vertical: true)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 20))

      Button("重试预览") {
        Task { await model.loadInitialSnapshotPreview() }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(ModernAirTheme.tide)
      .frame(maxWidth: .infinity, minHeight: 44)
      .accessibilityIdentifier("retrySnapshotPreviewButton")

      Button("先使用本地模式", action: onContinueLocal)
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(ModernAirTheme.tide)
    }
  }

  private var refreshFailureContent: some View {
    VStack(spacing: 16) {
      Label(
        model.snapshotImportErrorMessage
          ?? "导入已完成，但界面刷新失败。请重新载入已导入资料。",
        systemImage: "arrow.clockwise.icloud.fill"
      )
      .font(.subheadline)
      .foregroundStyle(ModernAirTheme.ink)
      .fixedSize(horizontal: false, vertical: true)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 20))

      Button("重新载入已导入资料") {
        Task { await model.reloadImportedSnapshot() }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(ModernAirTheme.tide)
      .frame(maxWidth: .infinity, minHeight: 44)
      .accessibilityIdentifier("retryImportedSnapshotRefreshButton")
      .accessibilityHint("只重新读取本机资料，不会再次导入服务器快照")
    }
  }

  @ViewBuilder
  private func previewContent(_ preview: SnapshotImportPreview) -> some View {
    VStack(spacing: 14) {
      Text("服务器中有 \(preview.remoteCount) 条生日")
        .font(.title3.weight(.semibold))
        .foregroundStyle(ModernAirTheme.ink)

      if preview.duplicates.isEmpty {
        Label("未发现可能重复，可以安全导入。", systemImage: "checkmark.seal.fill")
          .font(.subheadline)
          .foregroundStyle(ModernAirTheme.secondaryInk)
      } else {
        Text("发现 \(preview.duplicates.count) 组可能重复")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(ModernAirTheme.secondaryInk)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity)
    .modernAirSurface(radius: 24)

    ForEach(preview.duplicates) { candidate in
      duplicateCard(candidate)
    }

    if let error = model.snapshotImportErrorMessage {
      Label(error, systemImage: "exclamationmark.circle.fill")
        .font(.subheadline)
        .foregroundStyle(ModernAirTheme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 18))
    }

    Button {
      Task { await model.importInitialSnapshot() }
    } label: {
      HStack(spacing: 9) {
        if model.snapshotImportState == .importing {
          ProgressView()
            .tint(.white)
            .accessibilityHidden(true)
        } else {
          Image(systemName: "tray.and.arrow.down.fill")
            .accessibilityHidden(true)
        }
        Text(
          model.snapshotImportState == .importing
            ? "正在原子导入" : "导入 \(preview.remoteCount) 条生日"
        )
      }
      .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .tint(ModernAirTheme.tide)
    .disabled(!model.canImportInitialSnapshot || model.snapshotImportState == .importing)
    .accessibilityIdentifier("importSnapshotButton")
    .accessibilityHint("所有重复项都做出选择后，才会一次性导入")

    Button("取消导入，先使用本地模式", action: onContinueLocal)
      .buttonStyle(.bordered)
      .controlSize(.large)
      .tint(ModernAirTheme.tide)
      .disabled(model.snapshotImportState == .importing)
  }

  private func duplicateCard(_ candidate: DuplicateCandidate) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("可能是同一个生日", systemImage: "rectangle.on.rectangle.angled")
        .font(.headline)
        .foregroundStyle(ModernAirTheme.ink)

      HStack(alignment: .top, spacing: 12) {
        duplicateSummary(
          title: "本机",
          name: candidate.local.name,
          month: candidate.local.lunarBirthday.month,
          day: candidate.local.lunarBirthday.day
        )
        duplicateSummary(
          title: "服务器",
          name: candidate.remote.name,
          month: candidate.remote.lunarMonth,
          day: candidate.remote.lunarDay
        )
      }

      HStack(spacing: 10) {
        decisionButton(
          "保留两条",
          decision: .keepBoth,
          candidate: candidate,
          identifier: "keepBothDuplicateButton"
        )
        decisionButton(
          "采用服务器版本",
          decision: .useRemote,
          candidate: candidate,
          identifier: "useRemoteDuplicateButton"
        )
      }
    }
    .padding(18)
    .modernAirSurface(radius: 24)
  }

  private func duplicateSummary(
    title: String,
    name: String,
    month: Int,
    day: Int
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(ModernAirTheme.secondaryInk)
      Text(name)
        .font(.body.weight(.semibold))
        .foregroundStyle(ModernAirTheme.ink)
      Text("农历 \(month) 月 \(day) 日")
        .font(.caption)
        .foregroundStyle(ModernAirTheme.secondaryInk)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 16))
  }

  private func decisionButton(
    _ title: String,
    decision: DuplicateDecision,
    candidate: DuplicateCandidate,
    identifier: String
  ) -> some View {
    let isSelected = model.snapshotDecision(for: candidate.id) == decision
    return Button(title) {
      model.chooseSnapshotDuplicate(decision, candidateID: candidate.id)
    }
    .buttonStyle(.plain)
    .font(.subheadline.weight(.semibold))
    .foregroundStyle(isSelected ? .white : ModernAirTheme.ink)
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, minHeight: 44)
    .background(
      isSelected ? ModernAirTheme.tide : ModernAirTheme.glacier,
      in: RoundedRectangle(cornerRadius: 14)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(isSelected ? ModernAirTheme.tide : ModernAirTheme.outline, lineWidth: 1)
    }
    .frame(maxWidth: .infinity, minHeight: 44)
    .accessibilityIdentifier(identifier)
    .accessibilityValue(isSelected ? "已选择" : "未选择")
  }
}
