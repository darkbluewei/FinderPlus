import SwiftUI
import AppKit

/// 轻微立体感的小方块底：顶部高光、底部略暗、细描边、浮起的投影
struct RaisedBackground: View {
    let pressed: Bool
    let active: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        shape
            .fill(active ? Color.accentColor.opacity(0.20) : Color(nsColor: .controlBackgroundColor))
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: pressed
                            ? [Color.black.opacity(0.10), Color.black.opacity(0.02)]
                            : [Color.white.opacity(0.28), Color.black.opacity(0.07)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
            .overlay(
                shape
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.55), Color.clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                    .opacity(pressed ? 0 : 1)
            )
            .shadow(color: Color.black.opacity(pressed ? 0.05 : 0.22),
                    radius: pressed ? 0.5 : 1.5, x: 0, y: pressed ? 0 : 1)
    }
}

struct RaisedButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        RaisedButtonBody(configuration: configuration, active: active)
    }
}

struct RaisedButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 24)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .background(RaisedBackground(pressed: configuration.isPressed, active: active))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// 给 Menu 用的标签：和 RaisedButtonStyle 外观一致
struct RaisedLabel: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 24)
            .foregroundStyle(Color.primary)
            .background(RaisedBackground(pressed: false, active: false))
    }
}
