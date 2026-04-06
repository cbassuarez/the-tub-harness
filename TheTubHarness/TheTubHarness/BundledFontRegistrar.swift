import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import CoreText

private enum BundledFontRegistrarState {
    static var didRegister = false
}

enum BundledFontRegistrar {
    static func registerAll() {
        guard !BundledFontRegistrarState.didRegister else { return }
        BundledFontRegistrarState.didRegister = true

        let bundle = Bundle.main
        let fm = FileManager.default
        let roots: [URL] = [bundle.resourceURL, bundle.bundleURL]
            .compactMap { $0 }
            .filter { fm.fileExists(atPath: $0.path) }

        var seen = Set<String>()
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for case let url as URL in enumerator {
                let name = url.lastPathComponent
                guard name.hasPrefix("IBMPlexMono-"), url.pathExtension.lowercased() == "ttf" else { continue }
                let key = url.resolvingSymlinksInPath().path
                guard seen.insert(key).inserted else { continue }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

enum IBMPlexMonoFont {
    enum Variant {
        case thin
        case light
        case regular
        case medium
        case semibold
        case bold
        case italic
        case mediumItalic
        case boldItalic

        fileprivate var postScriptName: String {
            switch self {
            case .thin:
                return "IBMPlexMono-Thin"
            case .light:
                return "IBMPlexMono-Light"
            case .regular:
                return "IBMPlexMono-Regular"
            case .medium:
                return "IBMPlexMono-Medium"
            case .semibold:
                return "IBMPlexMono-SemiBold"
            case .bold:
                return "IBMPlexMono-Bold"
            case .italic:
                return "IBMPlexMono-Italic"
            case .mediumItalic:
                return "IBMPlexMono-MediumItalic"
            case .boldItalic:
                return "IBMPlexMono-BoldItalic"
            }
        }
    }

    static func font(_ variant: Variant, size: CGFloat) -> Font {
        Font.custom(variant.postScriptName, size: size)
    }

    #if canImport(AppKit)
    static func nsFont(_ variant: Variant, size: CGFloat) -> NSFont {
        NSFont(name: variant.postScriptName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    #elseif canImport(UIKit)
    static func uiFont(_ variant: Variant, size: CGFloat) -> UIFont {
        UIFont(name: variant.postScriptName, size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    #endif
}
