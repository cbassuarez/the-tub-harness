import SwiftUI

// Simple list of approved contributions. Uses HarnessClient to fetch list.
struct SoundBankBrowserView: View {
    @ObservedObject var harnessClient: HarnessClient
    var onSelect: (AudienceAudioContribution) -> Void
    
    @State private var contributions: [AudienceAudioContribution] = []
    @State private var isLoading = true
    
    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                } else if contributions.isEmpty {
                    Text("No approved contributions")
                        .foregroundColor(.gray)
                } else {
                    List(contributions, id: \.contributionId) { c in
                        Button(action: { onSelect(c) }) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(c.sessionId)
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.white)
                                    if let dur = c.durationMs {
                                        Text("\(dur / 1000)s")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.gray)
                                    }
                                }
                                Spacer()
                                Text(c.state.displayName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.gray)
                            }
                            .padding(8)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .navigationTitle("Sound Banks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { /* parent will dismiss sheet */ }
                }
            }
        }
        .onAppear { loadApproved() }
    }
    
    private func loadApproved() {
        isLoading = true
        harnessClient.fetchApprovedContributions { items in
            DispatchQueue.main.async {
                self.contributions = items
                self.isLoading = false
            }
        }
    }
}

#if DEBUG
struct SoundBankBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        SoundBankBrowserView(harnessClient: HarnessClient()) { _ in }
            .preferredColorScheme(.dark)
    }
}
#endif
