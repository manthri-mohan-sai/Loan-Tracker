import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Document Import View

/// Entry-point sheet for scanning or importing loan documents.
/// Orchestrates: source selection → OCR → classification + extraction → review.
struct DocumentImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    // Pipeline state
    @State private var stage: ImportStage = .choosingSource
    @State private var showingCamera = false
    @State private var showingFilePicker = false
    @State private var scannedImages: [UIImage] = []
    @State private var ocrText: String = ""
    @State private var markdownText: String = ""
    @State private var extractionResult: DocumentExtractionResult?
    @State private var isProcessing = false
    @State private var processingStep: String = ""
    @State private var errorMessage: String?

    // Fallback
    @State private var showingManualEntry = false
    @State private var isAwaitingUserMarkdownConfirmation = false

    /// Optional URL passed in when the app is opened with a shared file.
    var importedFileURL: URL?

    /// When set, the import applies to this specific loan (per-loan import).
    var targetLoan: Loan?

    enum ImportStage {
        case choosingSource
        case processing
        case confirmingMarkdown
        case reviewing
    }

    var body: some View {
        Group {
            switch stage {
            case .choosingSource:
                sourcePickerView
            case .processing:
                processingView
            case .confirmingMarkdown:
                markdownConfirmationView
            case .reviewing:
                if let result = extractionResult {
                    DocumentReviewView(result: result, targetLoan: targetLoan, onDismiss: { dismiss() })
                }
            }
        }
        .sheet(isPresented: $showingCamera) {
            DocumentCameraRepresentable(
                scannedImages: $scannedImages,
                isPresented: $showingCamera
            )
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.pdf, .image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showingManualEntry) {
            LoanFormView(loan: targetLoan)
        }
        .onChange(of: scannedImages) { _, newImages in
            guard !newImages.isEmpty else { return }
            startPipelineFromImages(newImages)
        }
        .task {
            // If opened with a file URL, start processing immediately
            if let url = importedFileURL {
                startPipelineFromFile(url)
            }
        }
    }

    // MARK: - Source Picker

    private var sourcePickerView: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Import a Loan Document")
                    .font(.title2.weight(.bold))

                Text("Scan a physical document or import a PDF. The app will automatically identify the document type and extract relevant details.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        showingCamera = true
                    } label: {
                        Label("Scan with Camera", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Import from Files", systemImage: "folder.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("Scan Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Processing View

    private var processingView: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if let error = errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)

                    Text("Something went wrong")
                        .font(.title3.weight(.semibold))

                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    HStack(spacing: 16) {
                        Button("Try Again") {
                            errorMessage = nil
                            stage = .choosingSource
                        }
                        .buttonStyle(.bordered)

                        Button("Enter Manually") {
                            showingManualEntry = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView()
                        .scaleEffect(1.5)

                    Text(processingStep)
                        .font(.headline)

                    Text("All processing happens on your device.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .navigationTitle("Processing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var markdownConfirmationView: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Text("Review Converted Text")
                    .font(.title2.weight(.bold))

                ScrollView {
                    Text(markdownText)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .padding(.horizontal)

                Text("Is the converted text correct? If not, you can cancel and try another method.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: 16) {
                    Button("Cancel") {
                        stage = .choosingSource
                    }
                    .buttonStyle(.bordered)

                    Button("Continue") {
                        continueAfterMarkdownConfirmation()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            .navigationTitle("Converted Text")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Pipeline

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            startPipelineFromFile(url)
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startPipelineFromImages(_ images: [UIImage]) {
        stage = .processing
        processingStep = "Recognizing text…"
        markdownText = ""

        Task {
            do {
                let text = try await OCRService.recognizeText(in: images)
                ocrText = text
                await runExtraction()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startPipelineFromFile(_ url: URL) {
        stage = .processing
        processingStep = "Reading document…"

        Task {
            do {
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }

                if url.pathExtension.lowercased() == "pdf" {
                    processingStep = "Converting PDF to markdown…"
                    let conversion = try await MarkdownConversion.convertPDF(at: url)
                    markdownText = conversion.markdownText
                    ocrText = conversion.rawText
                    stage = .confirmingMarkdown
                } else {
                    let text = try await OCRService.extractText(from: url)
                    ocrText = text
                    markdownText = ""
                    await runExtraction()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func runExtraction() async {
        processingStep = "Extracting details…"

        do {
            let extractor = DocumentExtractorFactory.makeExtractor()
            let result = try await extractor.classifyAndExtract(
                ocrText: ocrText,
                markdownText: markdownText.isEmpty ? nil : markdownText
            )

            extractionResult = result
            stage = .reviewing
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func continueAfterMarkdownConfirmation() {
        stage = .processing
        Task { await runExtraction() }
    }
}

// MARK: - Private helpers

private let NSUserCancelledError = 3072  // NSCocoaErrorDomain user cancelled code

