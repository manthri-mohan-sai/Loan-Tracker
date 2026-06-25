import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Document Import View

/// Entry-point sheet for scanning or importing loan documents.
/// Orchestrates: source selection → OCR → LLM classification + extraction → review.
struct DocumentImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    // Pipeline state
    @State private var stage: ImportStage = .choosingSource
    @State private var showingCamera = false
    @State private var showingFilePicker = false
    @State private var scannedImages: [UIImage] = []
    @State private var ocrText: String = ""
    @State private var extractionResult: DocumentExtractionResult?
    @State private var isProcessing = false
    @State private var processingStep: String = ""
    @State private var errorMessage: String?

    // Fallback
    @State private var showingManualEntry = false

    /// Optional URL passed in when the app is opened with a shared file.
    var importedFileURL: URL?

    /// When set, the import applies to this specific loan (per-loan import).
    var targetLoan: Loan?

    enum ImportStage {
        case choosingSource
        case processing
        case reviewing
    }

    var body: some View {
        Group {
            switch stage {
            case .choosingSource:
                sourcePickerView
            case .processing:
                processingView
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

                let text = try await OCRService.extractText(from: url)
                ocrText = text
                await runExtraction()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startPipeline() {
        // Retry after model download — if we have OCR text, go straight to extraction
        if !ocrText.isEmpty {
            stage = .processing
            Task { await runExtraction() }
        } else {
            stage = .choosingSource
        }
    }

    @MainActor
    private func runExtraction() async {
        let (extractor, source) = DocumentExtractorFactory.makeExtractor()

        switch source {
        case .appleIntelligence:
            processingStep = "Analyzing with Apple Intelligence…"
        case .downloadedModel:
            processingStep = "Analyzing with on-device model…"
        case .regexFallback:
            processingStep = "Extracting details…"
        }

        do {
            let result = try await extractor.classifyAndExtract(ocrText: ocrText)

            extractionResult = result
            stage = .reviewing
        } catch {
            // If CoreML or Apple Intelligence fails, fall back to regex
            if source != .regexFallback {
                let fallback = RegexExtractor()
                do {
                    processingStep = "Retrying with pattern matching…"
                    let result = try await fallback.classifyAndExtract(ocrText: ocrText)
                    extractionResult = result
                    stage = .reviewing
                    return
                } catch {
                    // Regex also failed — show the error
                }
            }
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Private helpers

private let NSUserCancelledError = 3072  // NSCocoaErrorDomain user cancelled code
