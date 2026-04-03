//
//  FontRegistry.swift
//  TubCompanion
//
//  iOS font registration (mirroring Mac BundledFontRegistrar).
//  Loads IBM Plex Mono variants from app bundle.
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
        
        // Register IBM Plex Mono fonts from bundle
        registerIBMPlexMonoFonts()
    }
    
    private static func registerIBMPlexMonoFonts() {
        guard let bundle = Bundle.main.url(forResource: "Fonts", withExtension: nil) else {
            // Fonts may not be in separate bundle on iOS; try main bundle
            let fm = FileManager.default
            guard let resourceURL = Bundle.main.resourceURL else { return }
            
            do {
                let contents = try fm.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil)
                for url in contents where url.pathExtension.lowercased() == "ttf" && url.lastPathComponent.hasPrefix("IBMPlexMono") {
                    if let data = try? Data(contentsOf: url),
                       let provider = CGDataProvider(data: data as CFData),
                       let font = CGFont(provider) {
                        CTFontManagerRegisterGraphicsFont(font, nil)
                    }
                }
            } catch {
                // Silent fallback to system fonts
            }
            return
        }
        
        do {
            let fontURLs = try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
            for url in fontURLs where url.pathExtension.lowercased() == "ttf" {
                if let data = try? Data(contentsOf: url),
                   let provider = CGDataProvider(data: data as CFData),
                   let font = CGFont(provider) {
                    CTFontManagerRegisterGraphicsFont(font, nil)
                }
            }
        } catch {
            // Silent fallback to system fonts
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
    
    static func uiFont(_ variant: Variant, size: CGFloat) -> UIFont {
        UIFont(name: variant.postScriptName, size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

