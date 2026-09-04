import SwiftUI
import UIKit

enum ModernAirTheme {
  static let mist = dynamicColor(
    light: UIColor(red: 243 / 255, green: 250 / 255, blue: 249 / 255, alpha: 1),
    dark: UIColor(red: 14 / 255, green: 27 / 255, blue: 29 / 255, alpha: 1)
  )
  static let glacier = dynamicColor(
    light: UIColor(red: 234 / 255, green: 241 / 255, blue: 248 / 255, alpha: 1),
    dark: UIColor(red: 24 / 255, green: 35 / 255, blue: 43 / 255, alpha: 1)
  )
  static let tide = dynamicColor(
    light: UIColor(red: 35 / 255, green: 107 / 255, blue: 115 / 255, alpha: 1),
    dark: UIColor(red: 111 / 255, green: 186 / 255, blue: 193 / 255, alpha: 1)
  )
  static let dusk = dynamicColor(
    light: UIColor(red: 54 / 255, green: 94 / 255, blue: 140 / 255, alpha: 1),
    dark: UIColor(red: 145 / 255, green: 180 / 255, blue: 223 / 255, alpha: 1)
  )
  static let ink = dynamicColor(
    light: UIColor(red: 24 / 255, green: 48 / 255, blue: 52 / 255, alpha: 1),
    dark: UIColor(red: 237 / 255, green: 247 / 255, blue: 247 / 255, alpha: 1)
  )
  static let moon = dynamicColor(
    light: UIColor(red: 232 / 255, green: 184 / 255, blue: 90 / 255, alpha: 1),
    dark: UIColor(red: 241 / 255, green: 201 / 255, blue: 111 / 255, alpha: 1)
  )
  static let secondaryInk = dynamicColor(
    light: UIColor(red: 73 / 255, green: 96 / 255, blue: 100 / 255, alpha: 1),
    dark: UIColor(red: 180 / 255, green: 199 / 255, blue: 201 / 255, alpha: 1)
  )
  static let surface = dynamicColor(
    light: UIColor(red: 250 / 255, green: 253 / 255, blue: 253 / 255, alpha: 1),
    dark: UIColor(red: 26 / 255, green: 39 / 255, blue: 42 / 255, alpha: 1)
  )
  static let outline = dynamicColor(
    light: UIColor(red: 35 / 255, green: 107 / 255, blue: 115 / 255, alpha: 0.16),
    dark: UIColor(red: 111 / 255, green: 186 / 255, blue: 193 / 255, alpha: 0.28)
  )
  static let desktopCanvas = dynamicColor(
    light: UIColor(red: 239 / 255, green: 247 / 255, blue: 246 / 255, alpha: 1),
    dark: UIColor(red: 11 / 255, green: 23 / 255, blue: 25 / 255, alpha: 1)
  )
  static let detailCanvas = dynamicColor(
    light: UIColor(red: 247 / 255, green: 251 / 255, blue: 251 / 255, alpha: 1),
    dark: UIColor(red: 19 / 255, green: 31 / 255, blue: 34 / 255, alpha: 1)
  )

  static let cardRadius: CGFloat = 24

  private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
    Color(
      uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? dark : light
      }
    )
  }
}

private struct ModernAirSurface: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  let radius: CGFloat

  func body(content: Content) -> some View {
    content
      .background {
        if reduceTransparency {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(ModernAirTheme.surface)
        } else {
          RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.thinMaterial)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(ModernAirTheme.outline, lineWidth: 1)
      }
  }
}

extension View {
  func modernAirSurface(radius: CGFloat = ModernAirTheme.cardRadius) -> some View {
    modifier(ModernAirSurface(radius: radius))
  }
}
