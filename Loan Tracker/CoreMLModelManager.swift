//
//  CoreMLModelManager.swift
//  Loan Tracker
//
//  Created by Lokesh Polina on 27/06/26.
//


import Foundation
import Network

// MARK: - CoreML Model Manager
//
// Manages downloading and storing the Qwen2.5-0.5B GGUF model file.
// Uses URLSessionDownloadDelegate for real progress tracking.
// Model is stored in the app's Documents directory.

@Observable
final class CoreMLModelManager: NSObject {

    // MARK: - Shared Instance

    static let shared = CoreMLModelManager()

    // MARK: - Model State

    enum ModelState: Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case failed(String)

        static func == (lhs: ModelState, rhs: ModelState) -> Bool {
            switch (lhs, rhs) {
            case (.notDownloaded, .notDownloaded): return true
            case (.downloading(let a), .downloading(let b)): return a == b
            case (.downloaded, .downloaded): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    // MARK: - State

    private(set) var state: ModelState = .notDownloaded
    private var downloadTask: URLSessionDownloadTask?
    private var urlSession: URLSession?

    // MARK: - Paths

    private var modelDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LLMModels", isDirectory: true)
    }

    /// Path to the downloaded GGUF file.
    var modelURL: URL {
        modelDirectory.appendingPathComponent("Qwen2.5-0.5B-Instruct-Q4_K_M.gguf")
    }

    /// Remote HuggingFace download URL (~350 MB).
    private let remoteModelURL = URL(string:
        "https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf?download=true"
    )!

    // MARK: - Init

    private override init() {
        super.init()
        
        let exists = FileManager.default.fileExists(atPath: modelURL.path)
        print("Model path: \(modelURL.path)")
        print("File exists: \(exists)")
        
        if exists {
            let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path)
            let size = attrs?[.size] as? Int64 ?? 0
            print("File size: \(size) bytes")
            
            // Only mark as downloaded if file is actually substantial (> 100MB)
            if size > 100 * 1024 * 1024 {
                state = .downloaded
            } else {
                // File exists but is empty/corrupt — delete and re-download
                try? FileManager.default.removeItem(at: modelURL)
                state = .notDownloaded
            }
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 3600
        config.allowsCellularAccess = false
        urlSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: .main
        )
    }

    // MARK: - Download

    /// Start downloading the GGUF model.
    /// Checks for WiFi before starting.
    /// Safe to call multiple times — skips if already downloaded.
    func downloadModel() {
        guard state != .downloaded else { return }

        do {
            try FileManager.default.createDirectory(
                at: modelDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            state = .failed("Could not create model directory: \(error.localizedDescription)")
            return
        }

        // Delete any existing corrupt/partial file
        if FileManager.default.fileExists(atPath: modelURL.path) {
            try? FileManager.default.removeItem(at: modelURL)
        }

        state = .downloading(progress: 0)

        // Use URLRequest with headers to bypass HuggingFace redirect
        var request = URLRequest(url: remoteModelURL)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        downloadTask = urlSession?.downloadTask(with: request)
        downloadTask?.resume()
    }

    // MARK: - Cancel

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .notDownloaded
    }

    // MARK: - Delete

    /// Delete the downloaded model to free disk space.
    func deleteModel() {
        try? FileManager.default.removeItem(at: modelURL)
        Task { await LocalLLMService.shared.unload() }
        state = .notDownloaded
    }

    // MARK: - Disk Size

    /// Size of the downloaded model file in bytes.
    var modelSizeOnDisk: Int64? {
        guard state == .downloaded else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: modelURL.path)
        return attrs?[.size] as? Int64
    }

    /// Human-readable model size string, e.g. "347 MB".
    var modelSizeString: String {
        guard let bytes = modelSizeOnDisk else { return "~350 MB" }
        let mb = Double(bytes) / (1024 * 1024)
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Network Check

    /// Returns true if the device is on cellular only (no WiFi).
    private func isOnCellularOnly() -> Bool {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var isCellular = false

        monitor.pathUpdateHandler = { path in
            isCellular = path.usesInterfaceType(.cellular) &&
                        !path.usesInterfaceType(.wifi)
            semaphore.signal()
        }

        let queue = DispatchQueue(label: "NetworkCheck")
        monitor.start(queue: queue)
        semaphore.wait()
        monitor.cancel()

        return isCellular
    }
}

// MARK: - URLSessionDownloadDelegate

extension CoreMLModelManager: URLSessionDownloadDelegate {

    // Called repeatedly during download with progress info
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        state = .downloading(progress: progress)
    }

    // Called when download completes — move file to permanent location
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            // Remove old file if exists
            if FileManager.default.fileExists(atPath: modelURL.path) {
                try FileManager.default.removeItem(at: modelURL)
            }
            // Move from temp location to permanent path
            try FileManager.default.moveItem(at: location, to: modelURL)
            state = .downloaded
        } catch {
            state = .failed("Failed to save model: \(error.localizedDescription)")
        }
    }

    // Called on error or cancellation
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        // Ignore cancellation — handled by cancelDownload()
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }

        state = .failed(error.localizedDescription)
    }
}

// MARK: - SwiftUI Helpers

extension CoreMLModelManager {

    /// Progress value 0.0–1.0, nil if not downloading.
    var downloadProgress: Double? {
        if case .downloading(let p) = state { return p }
        return nil
    }

    /// Human-readable downloaded size during active download.
    func downloadedSizeString(progress: Double) -> String {
        let totalMB = 350.0
        let downloadedMB = totalMB * progress
        return String(format: "%.0f MB of ~350 MB", downloadedMB)
    }

    /// True if model is ready to use.
    var isReady: Bool { state == .downloaded }

    /// Error message if in failed state.
    var errorMessage: String? {
        if case .failed(let msg) = state { return msg }
        return nil
    }
}
