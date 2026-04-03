import SwiftUI
import UIKit
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// Simple file picker wrapper for selecting audio files.
struct FileBrowserView: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        #if canImport(UniformTypeIdentifiers)
        let audioTypes: [UTType] = {
            var types: [UTType] = []
            // UTType.audio is non-optional on modern SDKs
            types.append(UTType.audio)
            if let w = UTType(filenameExtension: "wav") { types.append(w) }
            if let c = UTType(filenameExtension: "caf") { types.append(c) }
            if let m = UTType(filenameExtension: "m4a") { types.append(m) }
            return types
        }()
        #else
        let audioTypes: [String] = ["public.audio"]
        #endif
        
        #if canImport(UniformTypeIdentifiers)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: audioTypes, asCopy: true)
        #else
        let picker = UIDocumentPickerViewController(documentTypes: audioTypes, in: .import)
        #endif
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

#if DEBUG
struct FileBrowserView_Previews: PreviewProvider {
    static var previews: some View {
        Text("File Browser Placeholder")
    }
}
#endif
