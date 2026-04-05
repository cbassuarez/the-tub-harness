//
//  ToastView.swift
//  TubCompanion
//
//  Reusable toast notification component with auto-dismiss.
//  Styles: success (glyphGreen), warning (warningYellow), error (aberrationMagenta), info (gray).
//

import SwiftUI

// MARK: - Toast Model

struct Toast: Identifiable, Equatable {
    let id: UUID = UUID()
    let message: String
    let style: ToastStyle
    let duration: TimeInterval
    
    enum ToastStyle {
        case success
        case warning
        case error
        case info
    }
    
    init(message: String, style: ToastStyle = .info, duration: TimeInterval? = nil) {
        self.message = message
        self.style = style
        self.duration = duration ?? {
            switch style {
            case .success, .info:
                return 2.0
            case .warning:
                return 3.0
            case .error:
                return 4.0
            }
        }()
    }
}

// MARK: - Toast View

struct ToastView: View {
    let toast: Toast
    var onDismiss: () -> Void = {}
    
    @State private var isVisible = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                icon
                
                Text(toast.message)
                    .playSans(11, weight: .semibold)
                    .foregroundColor(foregroundColor)
                    .lineLimit(2)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(backgroundColor)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.95, anchor: .center)
        .animation(.easeInOut(duration: 0.3), value: isVisible)
        .onAppear {
            isVisible = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + toast.duration) {
                isVisible = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onDismiss()
                }
            }
        }
        .accessibilityLabel(Text(toast.message))
        .accessibilityHint(Text("Toast notification: \(toast.style)"))
    }
    
    // MARK: - Style Properties
    
    @ViewBuilder
    private var icon: some View {
        switch toast.style {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(BrandingColors.glyphGreen)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityLabel(Text("Success"))
        
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(BrandingColors.warningYellow)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityLabel(Text("Warning"))
        
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(BrandingColors.aberrationMagenta)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityLabel(Text("Error"))
        
        case .info:
            Image(systemName: "info.circle.fill")
                .foregroundColor(BrandingColors.textGray)
                .font(.system(size: 14, weight: .semibold))
                .accessibilityLabel(Text("Information"))
        }
    }
    
    private var backgroundColor: Color {
        switch toast.style {
        case .success:
            return BrandingColors.glyphGreen.opacity(0.08)
        case .warning:
            return BrandingColors.warningYellow.opacity(0.08)
        case .error:
            return BrandingColors.aberrationMagenta.opacity(0.08)
        case .info:
            return Color.white.opacity(0.04)
        }
    }
    
    private var borderColor: Color {
        switch toast.style {
        case .success:
            return BrandingColors.glyphGreen.opacity(0.3)
        case .warning:
            return BrandingColors.warningYellow.opacity(0.3)
        case .error:
            return BrandingColors.aberrationMagenta.opacity(0.3)
        case .info:
            return Color.white.opacity(0.1)
        }
    }
    
    private var foregroundColor: Color {
        switch toast.style {
        case .success:
            return BrandingColors.glyphGreen
        case .warning:
            return BrandingColors.warningYellow
        case .error:
            return BrandingColors.aberrationMagenta
        case .info:
            return BrandingColors.textGray
        }
    }
}

// MARK: - Toast Container View

struct ToastContainerView: View {
    @Binding var toasts: [Toast]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(toasts) { toast in
                ToastView(toast: toast) {
                    toasts.removeAll { $0.id == toast.id }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }
}

// MARK: - Convenience Modifier

extension View {
    func toastContainer(_ toasts: Binding<[Toast]>) -> some View {
        ZStack(alignment: .topLeading) {
            self
            
            ToastContainerView(toasts: toasts)
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        BrandingColors.darkBackground.ignoresSafeArea()
        
        VStack(spacing: 12) {
            ToastView(toast: Toast(message: "Cable detected!", style: .success))
            ToastView(toast: Toast(message: "Connection attempt in progress", style: .info))
            ToastView(toast: Toast(message: "Check your cable connection", style: .warning))
            ToastView(toast: Toast(message: "Local link not established", style: .error))
            
            Spacer()
        }
        .padding(16)
    }
}
