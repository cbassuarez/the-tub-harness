//
//  BrandingUI.swift
//  TubCompanion
//
//  Design system helpers: colors, typography, spacing, safe-area handling.
//  Mirrors the Mac harness visual language: monitor/terminal aesthetic, aberration-ready.
//

import SwiftUI

// MARK: - Color System

enum BrandingColors {
    // Monitor/terminal aesthetic
    static let darkBackground = Color(UIColor(named: "DarkBackground") ?? UIColor(red: 0.04, green: 0.055, blue: 0.153, alpha: 1))
    static let glyphGreen = Color(UIColor(named: "GlyphGreen") ?? UIColor(red: 0, green: 1, blue: 0.255, alpha: 1))
    static let aberrationCyan = Color(UIColor(named: "AberrationCyan") ?? UIColor(red: 0, green: 0.961, blue: 1, alpha: 1))
    static let aberrationMagenta = Color(UIColor(named: "AberrationMagenta") ?? UIColor(red: 1, green: 0, blue: 0.431, alpha: 1))
    
    static let gridGray = Color(red: 0.1, green: 0.122, blue: 0.227)
    static let textGray = Color(red: 0.4, green: 0.4, blue: 0.4)
    static let warningYellow = Color(red: 1, green: 0.745, blue: 0.04)
    static let successGreen = Color(red: 0.22, green: 0.631, blue: 0.41)
}

// MARK: - Typography

enum BrandingTypography {
    enum Size {
        static let displayLarge: CGFloat = 28
        static let displayMedium: CGFloat = 24
        static let headingLarge: CGFloat = 18
        static let headingMedium: CGFloat = 14
        static let bodyLarge: CGFloat = 12
        static let bodySmall: CGFloat = 11
        static let labelSmall: CGFloat = 10
        static let labelTiny: CGFloat = 9
    }

    // Public Sans — UI voice (titles, buttons, labels, instructions)
    static func displayFont(size: CGFloat = Size.displayMedium) -> Font {
        PublicSansFont.font(.bold, size: size)
    }
    static func headingFont(size: CGFloat = Size.headingMedium) -> Font {
        PublicSansFont.font(.bold, size: size)
    }
    static func subheadingFont(size: CGFloat = Size.bodyLarge) -> Font {
        PublicSansFont.font(.semibold, size: size)
    }
    static func buttonFont(size: CGFloat = Size.bodySmall) -> Font {
        PublicSansFont.font(.semibold, size: size)
    }
    static func captionFont(size: CGFloat = Size.labelSmall) -> Font {
        PublicSansFont.font(.medium, size: size)
    }
    static func bodyFont(size: CGFloat = Size.bodySmall) -> Font {
        PublicSansFont.font(.regular, size: size)
    }

    // IBM Plex Mono — Data voice (values, statuses, timers, events)
    static func readoutLargeFont(size: CGFloat = Size.headingLarge) -> Font {
        IBMPlexMonoFont.font(.bold, size: size)
    }
    static func readoutFont(size: CGFloat = Size.bodySmall) -> Font {
        IBMPlexMonoFont.font(.semibold, size: size)
    }
    static func dataFont(size: CGFloat = Size.labelSmall) -> Font {
        IBMPlexMonoFont.font(.medium, size: size)
    }
    static func consoleFont(size: CGFloat = Size.labelSmall) -> Font {
        IBMPlexMonoFont.font(.regular, size: size)
    }
}

// MARK: - Shared Font View Extensions

extension View {
    /// IBM Plex Mono — data voice. UPPERCASE, wide tracking.
    func playMono(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        self.font(IBMPlexMonoFont.font(weight.toPlexVariant, size: size))
            .textCase(.uppercase)
            .tracking(1.1)
    }

    /// Public Sans — UI voice. Mixed case, tighter tracking.
    func playSans(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        let variant: PublicSansFont.Variant = {
            switch weight {
            case .bold, .black, .heavy: return .bold
            case .semibold:             return .semibold
            case .medium:               return .medium
            default:                    return .regular
            }
        }()
        let tracking: CGFloat = {
            switch weight {
            case .bold, .black, .heavy: return size >= 18 ? 0.8 : 0.9
            case .semibold:             return 0.7
            case .medium:               return 0.5
            default:                    return 0.3
            }
        }()
        return self.font(PublicSansFont.font(variant, size: size))
            .tracking(tracking)
    }
}

extension Font.Weight {
    var toPlexVariant: IBMPlexMonoFont.Variant {
        switch self {
        case .bold, .black, .heavy: return .bold
        case .semibold:             return .semibold
        case .medium:               return .medium
        case .light, .thin, .ultraLight: return .light
        default:                    return .regular
        }
    }
}

// MARK: - Spacing System

enum BrandingSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}

// MARK: - Safe Area & Layout Helpers

struct SafeAreaPadding: ViewModifier {
    let edges: Edge.Set
    let length: CGFloat?
    
    func body(content: Content) -> some View {
        content
            .padding(edges, length ?? BrandingSpacing.md)
    }
}

extension View {
    func safeAreaPadding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View {
        modifier(SafeAreaPadding(edges: edges, length: length))
    }
}

struct ResponsivePadding: ViewModifier {
    @Environment(\.verticalSizeClass) var verticalSize
    @Environment(\.horizontalSizeClass) var horizontalSize
    let compact: CGFloat
    let regular: CGFloat
    
    func body(content: Content) -> some View {
        let padding = horizontalSize == .compact ? compact : regular
        return content.padding(padding)
    }
}

extension View {
    func responsivePadding(compact: CGFloat = BrandingSpacing.sm, regular: CGFloat = BrandingSpacing.md) -> some View {
        modifier(ResponsivePadding(compact: compact, regular: regular))
    }
}

// MARK: - Reusable Components

struct HeaderView: View {
    let title: String
    let subtitle: String?
    let trailing: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .playSans(12, weight: .bold)
                    .foregroundColor(.gray)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .playSans(14, weight: .semibold)
                        .foregroundColor(.white)
                }
            }
            Spacer()
            if let trailing = trailing {
                Text(trailing)
                    .playMono(10, weight: .bold)
                    .foregroundColor(BrandingColors.glyphGreen)
            }
        }
        .padding(BrandingSpacing.md)
        .borderBottom(color: Color.white.opacity(0.1))
    }
}

struct BorderedContainer: View {
    let content: () -> AnyView
    
    var body: some View {
        content()
            .padding(BrandingSpacing.md)
            .background(Color.white.opacity(0.05))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
    }
}

struct PrimaryButton: View {
    let label: String
    let action: () -> Void
    let isDisabled: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .playSans(12, weight: .semibold)
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(BrandingSpacing.sm)
                .background(BrandingColors.glyphGreen)
                .cornerRadius(4)
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

struct SecondaryButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .playSans(12, weight: .semibold)
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity)
                .padding(BrandingSpacing.sm)
                .background(Color.white.opacity(0.05))
                .cornerRadius(4)
        }
    }
}

struct StatusIndicator: View {
    let isActive: Bool
    let label: String

    var body: some View {
        HStack(spacing: BrandingSpacing.sm) {
            Circle()
                .fill(isActive ? BrandingColors.glyphGreen : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)

            Text(label)
                .playMono(11)
                .foregroundColor(isActive ? BrandingColors.glyphGreen : .gray)
        }
    }
}

// MARK: - TubCorp Wordmark

struct TubCorpWordmark: View {
    var height: CGFloat = 36

    var body: some View {
        if let url = Bundle.main.url(forResource: "tubcorp-wordmark", withExtension: "png"),
           let data = try? Data(contentsOf: url),
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .renderingMode(.original)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
        }
    }
}

// MARK: - Theme Modifiers

struct TubTheme: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(BrandingColors.darkBackground.ignoresSafeArea())
            .preferredColorScheme(.dark)
    }
}

extension View {
    func tubThemed() -> some View {
        modifier(TubTheme())
    }
}

// MARK: - Chromatic Aberration Helpers (Lightweight)

struct ChromaticAberrationModifier: ViewModifier {
    let offset: CGFloat = 1.0
    
    func body(content: Content) -> some View {
        ZStack {
            // Red channel offset
            content
                .foregroundColor(BrandingColors.aberrationMagenta)
                .offset(x: offset, y: offset)
                .opacity(0.1)
            
            // Cyan channel offset
            content
                .foregroundColor(BrandingColors.aberrationCyan)
                .offset(x: -offset, y: -offset)
                .opacity(0.1)
            
            // Center
            content
        }
    }
}

extension View {
    func chromaticAberration() -> some View {
        modifier(ChromaticAberrationModifier())
    }
}

// MARK: - Command Shell Primitives

struct CommandSignalRule: View {
    var opacity: Double = 0.13

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(opacity))
            .frame(height: 1)
    }
}

struct CommandStatusChip: View {
    let title: String
    let value: String
    var isActive: Bool
    var accent: Color = BrandingColors.glyphGreen

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .playSans(9, weight: .semibold)
                .foregroundStyle(Color.white.opacity(0.54))

            Text(value)
                .playMono(11, weight: .bold)
                .foregroundStyle(isActive ? accent : Color.white.opacity(0.76))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minHeight: 44, alignment: .leading)
        .overlay {
            Rectangle()
                .stroke(
                    isActive
                    ? accent.opacity(0.72)
                    : Color.white.opacity(0.18),
                    lineWidth: 1
                )
        }
    }
}

struct CommandRailButton: View {
    let title: String
    var isEnabled: Bool = true
    var isActive: Bool = false
    var isSolid: Bool = false
    var accent: Color = BrandingColors.glyphGreen
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .playSans(12, weight: .bold)
                .foregroundStyle(
                    !isEnabled
                    ? Color.white.opacity(0.32)
                    : (isSolid ? Color.black.opacity(0.92) : (isActive ? accent : Color.white.opacity(0.88)))
                )
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(
                    Group {
                        if isSolid {
                            Rectangle()
                                .fill(isEnabled ? accent.opacity(0.9) : Color.white.opacity(0.1))
                        } else if hovering {
                            Rectangle()
                                .fill(accent.opacity(0.08))
                        }
                    }
                )
                .overlay {
                    Rectangle()
                        .stroke(
                            !isEnabled
                            ? Color.white.opacity(0.16)
                            : (isSolid ? accent.opacity(0.95) : (isActive ? accent.opacity(0.72) : Color.white.opacity(hovering ? 0.34 : 0.2))),
                            lineWidth: 1
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .disabled(!isEnabled)
        .onHover { isHovering in
            hovering = isHovering
        }
    }
}
