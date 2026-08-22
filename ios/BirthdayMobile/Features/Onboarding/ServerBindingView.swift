import SwiftUI
import UIKit

struct ServerBindingView: View {
  @Bindable var model: AppModel
  let onSkip: () -> Void
  let onBound: () -> Void

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
    onSkip: @escaping () -> Void,
    onBound: @escaping () -> Void
  ) {
    self.model = model
    self.onSkip = onSkip
    self.onBound = onBound
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
            Text(isBinding ? "正在安全绑定" : "绑定并查看预览")
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(ModernAirTheme.tide)
        .disabled(isBinding)
        .accessibilityIdentifier("bindServerButton")
        .accessibilityHint("使用当前填写的账号绑定此设备，成功后查看首次导入预览")

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
        Text("连接服务器（可选）")
          .font(.system(.largeTitle, design: .rounded, weight: .bold))
          .multilineTextAlignment(.center)
          .foregroundStyle(ModernAirTheme.ink)

        Text("绑定后会先进入导入预览；确认前不会改动本机生日资料，也不会推进同步游标。跳过后仍可完整离线使用。")
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
