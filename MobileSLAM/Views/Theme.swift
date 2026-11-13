import SwiftUI

/// Small design system.
enum Theme {
    static let bg = Color(red: 0x0B / 255, green: 0x0D / 255, blue: 0x12 / 255)
    static let card = Color(red: 0x16 / 255, green: 0x1A / 255, blue: 0x22 / 255).opacity(0.8)
    static let text = Color(red: 0xE8 / 255, green: 0xEA / 255, blue: 0xF0 / 255)
    static let textDim = Color(red: 0x8A / 255, green: 0x91 / 255, blue: 0xA0 / 255)
    static let accent = Color(red: 0x3D / 255, green: 0x8B / 255, blue: 0xFF / 255)
    static let green = Color(red: 0x2E / 255, green: 0xCC / 255, blue: 0x71 / 255)
    static let orange = Color(red: 0xF5 / 255, green: 0xA6 / 255, blue: 0x23 / 255)
    static let red = Color(red: 0xFF / 255, green: 0x4D / 255, blue: 0x5E / 255)
    static let grey = Color(red: 0x59 / 255, green: 0x60 / 255, blue: 0x6E / 255)
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.2), lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 12) -> some View { modifier(CardBackground(padding: padding)) }
}

/// Pill button with a solid colour.
struct PillButton: View {
    let label: String
    var color: Color = Theme.grey
    var height: CGFloat = 44
    var fontSize: CGFloat = 15
    var radius: CGFloat? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: fontSize, weight: .bold))
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(RoundedRectangle(cornerRadius: radius ?? height / 2).fill(color))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Status chip with a coloured dot.
struct StatusChip: View {
    let ok: Bool
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? Theme.green : Theme.red).frame(width: 8, height: 8)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.13)))
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .padding(.horizontal, 24)
            .transition(.opacity)
    }
}
