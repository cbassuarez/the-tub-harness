import SwiftUI

enum ShellChromePalette {
    static let ink = Color(red: 0.11, green: 0.14, blue: 0.18)
    static let inkSoft = Color(red: 0.30, green: 0.35, blue: 0.42)
    static let border = Color.black.opacity(0.12)
    static let borderStrong = Color.black.opacity(0.20)
    static let surface = Color.white
    static let surfaceElevated = Color(red: 0.975, green: 0.982, blue: 0.995)
    static let surfaceMuted = Color(red: 0.95, green: 0.965, blue: 0.99)
    static let accentBlue = Color(red: 0.15, green: 0.42, blue: 0.88)
    static let accentBlueSoft = Color(red: 0.87, green: 0.92, blue: 0.99)
    static let startGreen = Color(red: 0.18, green: 0.68, blue: 0.38)
    static let startGreenSoft = Color(red: 0.88, green: 0.96, blue: 0.90)
    static let warmAmber = Color(red: 0.90, green: 0.63, blue: 0.18)
    static let warmAmberSoft = Color(red: 0.99, green: 0.95, blue: 0.84)
    static let dangerRed = Color(red: 0.78, green: 0.24, blue: 0.23)
    static let dangerRedSoft = Color(red: 0.99, green: 0.91, blue: 0.90)
}

enum ShellActionRole {
    case primaryTransport
    case secondaryAction
    case utilityAction
    case destructiveAction
}

enum ShellActionSize {
    case regular
    case compact

    var minHeight: CGFloat {
        switch self {
        case .regular: return 34
        case .compact: return 32
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular: return 14
        case .compact: return 12
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .regular: return 12
        case .compact: return 10
        }
    }

    var font: Font {
        switch self {
        case .regular:
            return .system(size: 13, weight: .semibold, design: .rounded)
        case .compact:
            return .system(size: 12, weight: .semibold, design: .rounded)
        }
    }

    var iconScale: Image.Scale {
        switch self {
        case .regular: return .medium
        case .compact: return .small
        }
    }
}

enum ShellStatusTone {
    case positive
    case active
    case idle
    case warning

    var fill: Color {
        switch self {
        case .positive: return ShellChromePalette.startGreenSoft
        case .active: return ShellChromePalette.accentBlueSoft
        case .idle: return ShellChromePalette.surfaceMuted
        case .warning: return ShellChromePalette.warmAmberSoft
        }
    }

    var border: Color {
        switch self {
        case .positive: return ShellChromePalette.startGreen.opacity(0.55)
        case .active: return ShellChromePalette.accentBlue.opacity(0.40)
        case .idle: return ShellChromePalette.borderStrong
        case .warning: return ShellChromePalette.warmAmber.opacity(0.55)
        }
    }

    var valueColor: Color {
        switch self {
        case .positive: return Color(red: 0.12, green: 0.44, blue: 0.24)
        case .active: return Color(red: 0.14, green: 0.32, blue: 0.64)
        case .idle: return ShellChromePalette.ink
        case .warning: return Color(red: 0.50, green: 0.34, blue: 0.05)
        }
    }
}

private struct ShellButtonVisuals {
    let foreground: Color
    let fill: Color
    let border: Color
    let shadow: Color
}

private struct ShellActionButtonBody<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled

    let label: Label
    let role: ShellActionRole
    let size: ShellActionSize
    let accent: Color?
    let isPressed: Bool

    private var visuals: ShellButtonVisuals {
        switch role {
        case .primaryTransport:
            let base = accent ?? ShellChromePalette.accentBlue
            return ShellButtonVisuals(
                foreground: .white,
                fill: base,
                border: base.opacity(0.88),
                shadow: base.opacity(0.22)
            )
        case .secondaryAction:
            let base = accent ?? ShellChromePalette.accentBlue
            return ShellButtonVisuals(
                foreground: ShellChromePalette.ink,
                fill: base.opacity(0.14),
                border: base.opacity(0.40),
                shadow: base.opacity(0.10)
            )
        case .utilityAction:
            return ShellButtonVisuals(
                foreground: ShellChromePalette.ink,
                fill: ShellChromePalette.surface,
                border: ShellChromePalette.borderStrong,
                shadow: Color.black.opacity(0.05)
            )
        case .destructiveAction:
            return ShellButtonVisuals(
                foreground: ShellChromePalette.dangerRed,
                fill: ShellChromePalette.dangerRedSoft,
                border: ShellChromePalette.dangerRed.opacity(0.45),
                shadow: ShellChromePalette.dangerRed.opacity(0.10)
            )
        }
    }

    private var pressedFill: Color {
        switch role {
        case .primaryTransport:
            return visuals.fill.opacity(0.92)
        case .secondaryAction:
            return visuals.fill.opacity(0.22)
        case .utilityAction:
            return ShellChromePalette.surfaceMuted
        case .destructiveAction:
            return visuals.fill.opacity(0.88)
        }
    }

    var body: some View {
        label
            .font(size.font)
            .imageScale(size.iconScale)
            .foregroundStyle(visuals.foreground.opacity(isEnabled ? 1.0 : 0.55))
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.minHeight)
            .background(
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .fill((isPressed ? pressedFill : visuals.fill).opacity(isEnabled ? 1.0 : 0.70))
            )
            .overlay {
                RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
                    .stroke(visuals.border.opacity(isEnabled ? 1.0 : 0.50), lineWidth: 1)
            }
            .shadow(color: visuals.shadow.opacity(isEnabled ? (isPressed ? 0.06 : 1.0) : 0.0), radius: isPressed ? 2 : 10, x: 0, y: isPressed ? 1 : 4)
            .scaleEffect(isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

struct ShellActionButtonStyle: ButtonStyle {
    let role: ShellActionRole
    var accent: Color? = nil
    var size: ShellActionSize = .regular

    func makeBody(configuration: Configuration) -> some View {
        ShellActionButtonBody(
            label: configuration.label,
            role: role,
            size: size,
            accent: accent,
            isPressed: configuration.isPressed
        )
    }
}

struct ShellPanelCardStyle: ViewModifier {
    let fill: Color
    let borderOpacity: Double
    let shadowOpacity: Double
    let contentPadding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .padding(contentPadding)
            .background(fill, in: shape)
            .clipShape(shape)
            .overlay {
                shape
                    .stroke(Color.black.opacity(borderOpacity), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(shadowOpacity), radius: 14, x: 0, y: 8)
    }
}

extension View {
    func shellPanelCard(
        fill: Color = ShellChromePalette.surface,
        borderOpacity: Double = 0.16,
        shadowOpacity: Double = 0.06,
        contentPadding: CGFloat = 12
    ) -> some View {
        modifier(ShellPanelCardStyle(fill: fill, borderOpacity: borderOpacity, shadowOpacity: shadowOpacity, contentPadding: contentPadding))
    }

    func shellActionButton(role: ShellActionRole, accent: Color? = nil, size: ShellActionSize = .regular) -> some View {
        buttonStyle(ShellActionButtonStyle(role: role, accent: accent, size: size))
    }
}

struct ShellPressAndHoldButton<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled

    let role: ShellActionRole
    var accent: Color? = nil
    var size: ShellActionSize = .regular
    var isActive: Bool = false
    let onPressChanged: (Bool) -> Void
    @ViewBuilder let label: () -> Label

    @State private var isPressed: Bool = false

    var body: some View {
        ShellActionButtonBody(
            label: label(),
            role: role,
            size: size,
            accent: accent,
            isPressed: isPressed || isActive
        )
        .contentShape(RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isEnabled, !isPressed else { return }
                    isPressed = true
                    onPressChanged(true)
                }
                .onEnded { _ in
                    guard isPressed else { return }
                    isPressed = false
                    onPressChanged(false)
                }
        )
        .onDisappear {
            guard isPressed else { return }
            isPressed = false
            onPressChanged(false)
        }
    }
}

struct ShellStatusPill: View {
    let title: String
    let value: String
    let tone: ShellStatusTone

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .textCase(.uppercase)
                .foregroundStyle(ShellChromePalette.inkSoft)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(tone.valueColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tone.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tone.border, lineWidth: 1)
        }
    }
}

struct ShellMetaTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(ShellChromePalette.inkSoft)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(ShellChromePalette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ShellChromePalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ShellChromePalette.border, lineWidth: 1)
        }
    }
}

struct ShellSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .tracking(0.2)
            .foregroundStyle(ShellChromePalette.ink.opacity(0.92))
    }
}

struct ShellSegmentedToggleItem<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let systemImage: String?

    var id: Value { value }
}

enum ShellSegmentedToggleSize {
    case regular
    case compact

    var minHeight: CGFloat {
        switch self {
        case .regular: return 34
        case .compact: return 30
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular: return 12
        case .compact: return 10
        }
    }

    var font: Font {
        switch self {
        case .regular: return .system(size: 12, weight: .semibold, design: .rounded)
        case .compact: return .system(size: 11, weight: .semibold, design: .rounded)
        }
    }
}

struct ShellSegmentedToggleGroup<Value: Hashable>: View {
    let items: [ShellSegmentedToggleItem<Value>]
    let isActive: (Value) -> Bool
    let toggle: (Value) -> Void
    var accent: Color = ShellChromePalette.accentBlue
    var size: ShellSegmentedToggleSize = .regular

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                let active = isActive(item.value)
                Button {
                    toggle(item.value)
                } label: {
                    HStack(spacing: item.systemImage == nil ? 0 : 6) {
                        if let systemImage = item.systemImage {
                            Image(systemName: systemImage)
                                .imageScale(size == .regular ? .small : .small)
                        }
                        Text(item.title)
                            .lineLimit(1)
                    }
                    .font(size.font)
                    .foregroundStyle(active ? Color.white : ShellChromePalette.ink)
                    .padding(.horizontal, size.horizontalPadding)
                    .frame(minHeight: size.minHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(active ? accent : ShellChromePalette.surface)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(
                                active ? accent.opacity(0.75) : ShellChromePalette.borderStrong,
                                lineWidth: 1
                            )
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(ShellChromePalette.surfaceMuted, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ShellChromePalette.border, lineWidth: 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
