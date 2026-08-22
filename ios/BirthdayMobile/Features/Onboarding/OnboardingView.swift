import SwiftUI

struct OnboardingView: View {
  @Bindable var model: AppModel
  @State private var page = 0

  var body: some View {
    ScrollView {
      VStack(spacing: 28) {
        stepIndicator

        if page == 0 {
          introduction(
            systemImage: "iphone.gen3",
            title: "离线也能完整使用",
            message: "生日资料保存在这台 iPhone 上。没有网络时，查看、添加、编辑和删除仍可立即完成。"
          )

          Button("继续") {
            page = 1
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(ModernAirTheme.tide)
          .frame(maxWidth: .infinity, minHeight: 44)
        } else if page == 1 {
          introduction(
            systemImage: "bell.badge.fill",
            title: "由 iPhone 按时提醒",
            message: "允许通知后，提醒会直接安排在本机。是否开启由你决定，也可以稍后在系统设置中更改。"
          )

          if let errorMessage = model.onboardingErrorMessage {
            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
              .font(.subheadline)
              .foregroundStyle(ModernAirTheme.ink)
              .fixedSize(horizontal: false, vertical: true)
              .padding(16)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 18))
              .accessibilityElement(children: .combine)
          }

          VStack(spacing: 12) {
            Button {
              continueAfterNotifications(requestNotifications: true)
            } label: {
              onboardingActionLabel("开启通知", systemImage: "bell.badge")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(ModernAirTheme.tide)

            Button("暂不开启") {
              continueAfterNotifications(requestNotifications: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(ModernAirTheme.tide)
          }
          .disabled(model.isCompletingOnboarding)
        } else if page == 2 {
          ServerBindingView(
            model: model,
            onSkip: {
              model.finishOnboarding()
            },
            onBound: {
              page = 3
            }
          )
        } else {
          SnapshotImportPreviewView(
            model: model,
            onContinueLocal: {
              model.finishOnboarding()
            }
          )
        }
      }
      .frame(maxWidth: 560)
      .padding(.horizontal, 24)
      .padding(.top, 40)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity)
    }
    .background(ModernAirTheme.mist.ignoresSafeArea())
  }

  private var stepIndicator: some View {
    HStack(spacing: 8) {
      Capsule()
        .fill(ModernAirTheme.tide)
        .frame(width: page == 0 ? 32 : 12, height: 6)
      Capsule()
        .fill(page == 1 ? ModernAirTheme.tide : ModernAirTheme.outline)
        .frame(width: page == 1 ? 32 : 12, height: 6)
      if model.isServerBindingAvailable {
        Capsule()
          .fill(page >= 2 ? ModernAirTheme.tide : ModernAirTheme.outline)
          .frame(width: page >= 2 ? 32 : 12, height: 6)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("引导进度")
    .accessibilityValue(
      "第 \(min(page, model.isServerBindingAvailable ? 2 : 1) + 1) 页，共 \(model.isServerBindingAvailable ? 3 : 2) 页"
    )
  }

  private func introduction(systemImage: String, title: String, message: String) -> some View {
    VStack(spacing: 22) {
      Image(systemName: systemImage)
        .font(.system(size: 46, weight: .medium))
        .foregroundStyle(ModernAirTheme.tide)
        .frame(width: 92, height: 92)
        .background(ModernAirTheme.glacier, in: RoundedRectangle(cornerRadius: 28))
        .accessibilityHidden(true)

      VStack(spacing: 12) {
        Text(title)
          .font(.system(.largeTitle, design: .rounded, weight: .bold))
          .multilineTextAlignment(.center)
          .foregroundStyle(ModernAirTheme.ink)

        Text(message)
          .font(.body)
          .multilineTextAlignment(.center)
          .foregroundStyle(ModernAirTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 32)
    .frame(maxWidth: .infinity)
    .modernAirSurface(radius: 30)
  }

  private func onboardingActionLabel(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 9) {
      if model.isCompletingOnboarding {
        ProgressView()
          .tint(.white)
          .accessibilityHidden(true)
      } else {
        Image(systemName: systemImage)
          .accessibilityHidden(true)
      }
      Text(model.isCompletingOnboarding ? "正在设置" : title)
    }
    .frame(maxWidth: .infinity, minHeight: 44)
  }

  private func continueAfterNotifications(requestNotifications: Bool) {
    guard !model.isCompletingOnboarding else { return }
    Task {
      if await model.prepareOnboardingNotifications(
        requestNotifications: requestNotifications
      ) {
        if model.isServerBindingAvailable {
          page = 2
        } else {
          model.finishOnboarding()
        }
      }
    }
  }
}
