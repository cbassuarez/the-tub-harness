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
    
    enum Weight {
        static let display: Font.Weight = .bold
        static let heading: Font.Weight = .semibold
        static let body: Font.Weight = .regular
        static let label: Font.Weight = .medium
    }
    
    // Convenience helpers
    static func displayFont(size: CGFloat = Size.displayMedium, weight: Font.Weight = .bold) -> Font {
        IBMPlexMonoFont.font(.bold, size: size)
    }
    
    static func headingFont(size: CGFloat = Size.headingMedium, weight: Font.Weight = .semibold) -> Font {
        IBMPlexMonoFont.font(.semibold, size: size)
    }
    
    static func bodyFont(size: CGFloat = Size.bodyLarge, weight: Font.Weight = .regular) -> Font {
        IBMPlexMonoFont.font(.regular, size: size)
    }
    
    static func labelFont(size: CGFloat = Size.labelSmall, weight: Font.Weight = .medium) -> Font {
        IBMPlexMonoFont.font(.medium, size: size)
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
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.gray)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
            }
            Spacer()
            if let trailing = trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
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
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
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
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
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
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(isActive ? BrandingColors.glyphGreen : .gray)
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
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.54))

            Text(value.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.0)
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
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(1)
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
