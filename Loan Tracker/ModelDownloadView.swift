//
//  ModelDownloadView.swift
//  Loan Tracker
//
//  Created by Lokesh Polina on 27/06/26.
//


import SwiftUI

struct ModelDownloadView: View {
    @State private var manager = CoreMLModelManager.shared

    var body: some View {
        VStack(spacing: 20) {
            switch manager.state {

            case .notDownloaded:
                notDownloadedView

            case .downloading(let progress):
                downloadingView(progress: progress)

            case .downloaded:
                downloadedView

            case .failed(let message):
                failedView(message: message)
            }
        }
        .padding()
        .onAppear {
            let path = CoreMLModelManager.shared.modelURL.path
            if let data = FileManager.default.contents(atPath: path),
               let content = String(data: data, encoding: .utf8) {
                print("File contents: \(content)")
            }
        }
    }

    // MARK: - States

    private var notDownloadedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("On-Device AI Model")
                .font(.title2.bold())

            Text("Download a 350MB model to process loan documents privately on your device. No data is ever sent to a server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Label("Requires WiFi", systemImage: "wifi")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                manager.downloadModel()
            } label: {
                Label("Download Model", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        
    }

    private func downloadingView(progress: Double) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse)

            Text("Downloading Model")
                .font(.title2.bold())

            ProgressView(value: progress)
                .tint(.accentColor)

            Text(manager.downloadedSizeString(progress: progress))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(Int(progress * 100))% complete")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                manager.cancelDownload()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    private var downloadedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Model Ready")
                .font(.title2.bold())

            Text("On-device AI is active. Your documents are processed privately.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let size = manager.modelSizeString as String? {
                Text("Model size: \(size)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                manager.deleteModel()
            } label: {
                Label("Delete Model", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.red)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Download Failed")
                .font(.title2.bold())

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                manager.downloadModel()
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
