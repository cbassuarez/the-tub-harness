//
//  AccessPasswordModal.swift
//  TubCompanion
//
//  Shared password prompt used before unlock challenges.
//

import SwiftUI

struct AccessPasswordModal: View {
    let idPrefix: String
    let title: String
    let subtitle: String
    let onCancel: () -> Void
    let onEnterSuccess: () -> Void
    let onHack: () -> Void

    @State private var input: String = ""
    @State private var statusLine: String = "ENTER 6-LETTER ACCESS TOKEN."
    @State private var deniedPulse = false
    @FocusState private var inputFocused: Bool

    private var sanitizedInput: String {
        CodeMatchChallengeCore.normalizedPassword(input)
    }

    private var tokenLength: Int {
        CodeMatchChallengeCore.accessPassword.count
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.86).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(title.uppercased())
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .tracking(1.3)
                        .foregroundStyle(Color.white.opacity(0.86))
                    Spacer()
                    Button(action: onCancel) {
                        Text("CANCEL")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.1)
                            .foregroundStyle(Color.white.opacity(0.82))
                            .frame(minWidth: 84, minHeight: 44)
                            .overlay {
                                Rectangle()
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(idPrefix).cancel")
                }

                Text(subtitle.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(BrandingColors.glyphGreen.opacity(0.9))

                tokenRow
                    .accessibilityIdentifier("\(idPrefix).entry")
                    .onTapGesture {
                        inputFocused = true
                    }

                Text(statusLine)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(deniedPulse ? BrandingColors.warningYellow : Color.white.opacity(0.68))

                TextField(
                    "",
                    text: Binding(
                        get: { input },
                        set: { input = CodeMatchChallengeCore.normalizedPassword($0) }
                    )
                )
                .textInputAutocapitalization(.characters)
                .disableAutocorrection(true)
                .keyboardType(.asciiCapable)
                .focused($inputFocused)
                .submitLabel(.go)
                .opacity(0.01)
                .frame(height: 1)
                .accessibilityIdentifier("\(idPrefix).input")
                .onSubmit {
                    runEnter()
                }

                HStack(spacing: 10) {
                    CommandRailButton(
                        title: "ENTER",
                        isEnabled: true,
                        isActive: true,
                        isSolid: true,
                        accent: BrandingColors.glyphGreen
                    ) {
                        runEnter()
                    }
                    .frame(minHeight: 46)
                    .accessibilityIdentifier("\(idPrefix).enter")

                    CommandRailButton(
                        title: "HACK",
                        isEnabled: true,
                        isActive: true,
                        accent: BrandingColors.warningYellow
                    ) {
                        runHack()
                    }
                    .frame(minHeight: 46)
                    .accessibilityIdentifier("\(idPrefix).hack")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: 420)
            .background(Color.black)
            .overlay {
                Rectangle()
                    .stroke(Color.white.opacity(0.24), lineWidth: 1)
            }
            .padding(.horizontal, 20)
        }
        .onAppear {
            statusLine = "ENTER 6-LETTER ACCESS TOKEN."
            deniedPulse = false
            inputFocused = true
        }
        .accessibilityIdentifier("\(idPrefix).modal")
    }

    private var tokenRow: some View {
        HStack(spacing: 8) {
            ForEach(0..<tokenLength, id: \.self) { index in
                let filled = index < sanitizedInput.count
                Text(filled ? "*" : "·")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(filled ? BrandingColors.glyphGreen : Color.white.opacity(0.42))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay {
                        Rectangle()
                            .stroke(
                                filled
                                ? BrandingColors.glyphGreen.opacity(0.72)
                                : Color.white.opacity(0.18),
                                lineWidth: 1
                            )
                    }
            }
        }
    }

    private func runEnter() {
        guard sanitizedInput.count == tokenLength else {
            statusLine = "TOKEN INCOMPLETE."
            return
        }

        if CodeMatchChallengeCore.isPasswordValid(sanitizedInput) {
            statusLine = "TOKEN ACCEPTED."
            onEnterSuccess()
            return
        }

        input = ""
        statusLine = "ACCESS DENIED. TRY AGAIN."
        deniedPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            deniedPulse = false
            inputFocused = true
        }
    }

    private func runHack() {
        statusLine = "TRACE MODE ARMED."
        onHack()
    }
}
