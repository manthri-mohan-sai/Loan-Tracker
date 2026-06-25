import SwiftUI
import VisionKit

// MARK: - Document Camera (UIViewControllerRepresentable)

/// Wraps VNDocumentCameraViewController for use in SwiftUI.
/// Returns scanned page images via a binding.
struct DocumentCameraRepresentable: UIViewControllerRepresentable {
    @Binding var scannedImages: [UIImage]
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentCameraRepresentable

        init(_ parent: DocumentCameraRepresentable) { self.parent = parent }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            parent.scannedImages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.isPresented = false
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.isPresented = false
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            print("⚠️ [DocumentCamera] Scan failed: \(error.localizedDescription)")
            parent.isPresented = false
        }
    }
}
