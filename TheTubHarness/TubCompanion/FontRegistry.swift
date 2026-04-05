//
//  FontRegistry.swift
//  TubCompanion
//
//  iOS font registration (mirroring Mac BundledFontRegistrar).
//  Loads IBM Plex Mono + Public Sans variants from app bundle.
//

import UIKit
import SwiftUI

private enum FontRegistryState {
    static var didRegister = false
}

enum FontRegistry {
    static func registerAllFonts() {
        guard !FontRegistryState.didRegister else { return }
        FontRegistryState.didRegister = true

        registerBundledTTFonts()
    }

    private static func registerBundledTTFonts() {
        // Try "Fonts" subfolder first, then fall back to flat bundle scan
        if let fontsDir = Bundle.main.url(forResource: "Fonts", withExtension: nil) {
            registerTTFs(in: fontsDir)
            return
        }

        guard let resourceURL = Bundle.main.resourceURL else { return }
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: resourceURL, includingPropertiesForKeys: nil
            )
            for url in contents where url.pathExtension.lowercased() == "ttf" {
                registerFont(at: url)
            }
        } catch {
            // Silent fallback to system fonts
        }
    }

    private static func registerTTFs(in directory: URL) {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
            for url in urls where url.pathExtension.lowercased() == "ttf" {
                registerFont(at: url)
            }
        } catch {
            // Silent fallback to system fonts
        }
    }

    private static func registerFont(at url: URL) {
        guard let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider) else { return }
        CTFontManagerRegisterGraphicsFont(font, nil)
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
            case .thin:        return "IBMPlexMono-Thin"
            case .light:       return "IBMPlexMono-Light"
            case .regular:     return "IBMPlexMono-Regular"
            case .medium:      return "IBMPlexMono-Medium"
            case .semibold:    return "IBMPlexMono-SemiBold"
            case .bold:        return "IBMPlexMono-Bold"
            case .italic:      return "IBMPlexMono-Italic"
            case .mediumItalic: return "IBMPlexMono-MediumItalic"
            case .boldItalic:  return "IBMPlexMono-BoldItalic"
            }
        }
    }

    static func font(_ variant: Variant, size: CGFloat) -> Font {
        Font.custom(variant.postScriptName, size: size)
    }

    static func uiFont(_ variant: Variant, size: CGFloat) -> UIFont {
        UIFont(name: variant.postScriptName, size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

enum PublicSansFont {
    enum Variant {
        case regular
        case medium
        case semibold
        case bold

        fileprivate var postScriptName: String {
            switch self {
            case .regular:  return "PublicSans-Regular"
            case .medium:   return "PublicSans-Medium"
            case .semibold: return "PublicSans-SemiBold"
            case .bold:     return "PublicSans-Bold"
            }
        }
    }

    static func font(_ variant: Variant, size: CGFloat) -> Font {
        Font.custom(variant.postScriptName, size: size)
    }

    static func uiFont(_ variant: Variant, size: CGFloat) -> UIFont {
        UIFont(name: variant.postScriptName, size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .regular)
    }
}

