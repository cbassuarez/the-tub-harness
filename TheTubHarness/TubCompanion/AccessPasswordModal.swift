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
    @State private var hasFailedTokenAuth = false
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
                        .playMono(13, weight: .bold)
                        .foregroundStyle(Color.white.opacity(0.86))
                    Spacer()

                    HStack(spacing: 8) {
                        if hasFailedTokenAuth {
                            Button(action: runHack) {
                                Text("Plugin:Hack")
                                    .playMono(10, weight: .bold)
                                    .foregroundStyle(BrandingColors.aberrationMagenta.opacity(0.95))
                                    .frame(minWidth: 112, minHeight: 44)
                                    .background(Color.black)
                                    .overlay {
                                        Rectangle()
                                            .stroke(
                                                BrandingColors.aberrationMagenta.opacity(0.88),
                                                style: StrokeStyle(lineWidth: 1, dash: [4, 2])
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                            .rotationEffect(.degrees(-0.8))
                            .accessibilityIdentifier("\(idPrefix).hack")
                        }

                        Button(action: onCancel) {
                            Text("Cancel")
                                .playMono(11, weight: .bold)
                                .foregroundStyle(Color.white.opacity(0.82))
                                .frame(minWidth: 84, minHeight: 44)
                                .overlay {
                                    Rectangle()
                                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("\(idPrefix).cancel")
                    }
                }

                Text(subtitle.uppercased())
                    .playMono(10, weight: .semibold)
                    .foregroundStyle(BrandingColors.glyphGreen.opacity(0.9))

                tokenRow
                    .accessibilityIdentifier("\(idPrefix).entry")
                    .onTapGesture {
                        inputFocused = true
                    }

                Text(statusLine)
                    .playMono(10, weight: .semibold)
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
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("\(idPrefix).enter")
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
            hasFailedTokenAuth = false
            inputFocused = true
        }
        .accessibilityIdentifier("\(idPrefix).modal")
    }

    private var tokenRow: some View {
        HStack(spacing: 8) {
            ForEach(0..<tokenLength, id: \.self) { index in
                let filled = index < sanitizedInput.count
                Text(filled ? "*" : "·")
                    .playMono(20, weight: .bold)
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
        hasFailedTokenAuth = true
        statusLine = "ACCESS DENIED. PLUGIN CHANNEL EXPOSED."
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
