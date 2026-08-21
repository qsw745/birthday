import SwiftUI

struct AppLockView: View {
  @Bindable var model: AppModel

  var body: some View {
    ScrollView {
      VStack(spacing: 26) {
        Image(systemName: "lock.shield.fill")
          .font(.system(size: 48, weight: .medium))
          .foregroundStyle(ModernAirTheme.tide)
          .frame(width: 96, height: 96)
          .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 30))
          .accessibilityHidden(true)

        VStack(spacing: 10) {
          Text("生日资料已锁定")
            .font(.system(.largeTitle, design: .rounded, weight: .bold))
            .multilineTextAlignment(.center)
            .foregroundStyle(ModernAirTheme.ink)

          Text(lockDescription)
            .font(.body)
            .multilineTextAlignment(.center)
            .foregroundStyle(ModernAirTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }

        if case .failed(let message) = model.unlockState {
          Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(ModernAirTheme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
        }

        Button {
          Task { await model.unlock() }
        } label: {
          HStack(spacing: 9) {
            if model.isUnlocking {
              ProgressView()
                .tint(.white)
                .accessibilityHidden(true)
            } else {
              Image(systemName: model.lockCapability == .faceID ? "faceid" : "lock.open")
                .accessibilityHidden(true)
            }
            Text(model.isUnlocking ? "正在验证" : "解锁")
          }
          .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(ModernAirTheme.tide)
        .disabled(model.isUnlocking)
        .accessibilityIdentifier("unlockButton")
        .accessibilityHint(unlockHint)
      }
      .frame(maxWidth: 520)
      .padding(.horizontal, 24)
      .padding(.vertical, 48)
      .frame(maxWidth: .infinity)
    }
    .background(ModernAirTheme.mist.ignoresSafeArea())
  }

  private var lockDescription: String {
    switch model.lockCapability {
    case .faceID:
      "使用 Face ID 或设备密码继续。验证只会在你轻点下方按钮后开始。"
    case .devicePasscode:
      "使用设备密码继续。验证只会在你轻点下方按钮后开始。"
    case .unavailable:
      "此设备当前无法验证身份，应用锁会自动保持关闭。"
    }
  }

  private var unlockHint: String {
    model.lockCapability == .faceID ? "开始 Face ID 或设备密码验证" : "开始设备密码验证"
  }
}
