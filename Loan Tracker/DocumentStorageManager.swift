import SwiftUI
import SwiftData

// MARK: - Document Storage Manager

enum DocumentStorageManager {

    private static var storageDirectory: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("LoanDocuments")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Store a file (PDF or image) and return the StoredDocument model.
    static func storeFile(
        sourceURL: URL,
        fileName: String,
        documentType: String,
        note: String? = nil
    ) throws -> StoredDocument {
        let isPDF = sourceURL.pathExtension.lowercased() == "pdf"
        let doc = StoredDocument(
            fileName: fileName,
            fileType: isPDF ? "pdf" : "image",
            documentType: documentType,
            note: note
        )

        guard let destURL = doc.fileURL else {
            throw StorageError.directoryUnavailable
        }

        // Ensure parent directory exists
        try FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Copy file
        if sourceURL.startAccessingSecurityScopedResource() {
            defer { sourceURL.stopAccessingSecurityScopedResource() }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } else {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        }

        return doc
    }

    /// Store images (from camera scan) as a single PDF or JPEG.
    static func storeImages(
        _ images: [UIImage],
        fileName: String,
        documentType: String,
        note: String? = nil
    ) throws -> StoredDocument {
        let doc = StoredDocument(
            fileName: fileName,
            fileType: "image",
            documentType: documentType,
            note: note
        )

        guard let destURL = doc.fileURL else {
            throw StorageError.directoryUnavailable
        }

        try FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Store first image as JPEG (or create multi-page if needed)
        if let first = images.first, let data = first.jpegData(compressionQuality: 0.85) {
            try data.write(to: destURL)
        }

        return doc
    }

    /// Delete the stored file from disk.
    static func deleteFile(_ document: StoredDocument) {
        guard let url = document.fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Total size of all stored documents.
    static var totalStorageSize: Int64 {
        guard let dir = storageDirectory else { return 0 }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    enum StorageError: LocalizedError {
        case directoryUnavailable

        var errorDescription: String? {
            switch self {
            case .directoryUnavailable: return "Could not access the documents directory."
            }
        }
    }
}

// MARK: - Documents List View

/// Shows all stored documents for a loan.
struct LoanDocumentsView: View {
    let loan: Loan
    @Environment(\.modelContext) private var context
    @State private var shareURL: URL?
    @State private var showingShareSheet = false

    private var documents: [StoredDocument] {
        (loan.storedDocuments ?? []).sorted { $0.addedDate > $1.addedDate }
    }

    var body: some View {
        if documents.isEmpty {
            ContentUnavailableView(
                "No Documents",
                systemImage: "doc.text",
                description: Text("Scanned or imported documents will appear here.")
            )
            .navigationTitle("Documents")
        } else {
            List {
                ForEach(documents) { doc in
                    HStack {
                        Image(systemName: doc.fileType == "pdf" ? "doc.fill" : "photo.fill")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.fileName)
                                .lineLimit(1)
                            HStack(spacing: 8) {
                                Text(doc.documentType)
                                Text(doc.addedDate, format: .dateTime.day().month(.abbreviated))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = doc.fileURL,
                           FileManager.default.fileExists(atPath: url.path) {
                            Button {
                                shareURL = url
                                showingShareSheet = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteDocuments)
            }
            .navigationTitle("Documents")
            .sheet(isPresented: $showingShareSheet) {
                if let url = shareURL {
                    ActivityViewController(activityItems: [url])
                }
            }
        }
    }

    private func deleteDocuments(at offsets: IndexSet) {
        for index in offsets {
            let doc = documents[index]
            DocumentStorageManager.deleteFile(doc)
            context.delete(doc)
        }
        try? context.save()
    }
}

// MARK: - Share Sheet

/// UIKit wrapper for UIActivityViewController used for sharing files.
struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
