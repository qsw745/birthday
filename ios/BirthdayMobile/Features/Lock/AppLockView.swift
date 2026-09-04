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
              Image(systemName: lockPresentation.iconName)
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
    lockPresentation.lockedDescription
  }

  private var unlockHint: String {
    lockPresentation.unlockHint
  }

  private var lockPresentation: AppLockPresentation {
    model.platformServices.lockPresentation(for: model.lockCapability)
  }
}
