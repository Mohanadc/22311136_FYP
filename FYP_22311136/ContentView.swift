import SwiftUI
import Foundation
import UniformTypeIdentifiers
import Metal

struct ContentView: View {
    @State private var output: String = "Ready to carve JPEG files"
    @State private var isSelectingFile = false
    @State private var selectedFilePath: String = ""
    @State private var selectedFileName: String = ""
    @State private var isCarving = false
    @State private var showHexPreview: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            Text("JPEG Carver")
                .font(.headline)

            if selectedFileName.isEmpty  {
                Button(action: { isSelectingFile = true }) {
                    Label("Select Raw Image (.img/.dmg/.iso)", systemImage: "doc.fill")
                        .padding(8)
                }
                .fileImporter(
                    isPresented: $isSelectingFile,
                    allowedContentTypes: [.item],
                    onCompletion: handleSelection
                )
            } else {
                HStack {
                    Text("Selected:")
                        .font(.caption)
                    Text(selectedFileName)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.green)

                    Spacer()

                    Button("Change") { isSelectingFile = true }.fileImporter(
                    isPresented: $isSelectingFile,
                    allowedContentTypes: [.item],
                    onCompletion: handleSelection
                )
                }
                .padding()
            }
        HStack {
    
            }
            .padding(.horizontal)
            if !selectedFilePath.isEmpty && !isCarving {
                Button(action: startCarving) {
                    Label("Start Carving", systemImage: "play.fill")
                        .padding(8)
                }
            }

            if isCarving {
                ProgressView()
                    .padding()
            }

            

            Toggle("Show hex preview (first 512 bytes)", isOn: $showHexPreview)
                .padding(.horizontal)

            ScrollView {
                Text(output)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .padding()
    }

    private func handleSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            selectedFilePath = url.path
            selectedFileName = url.lastPathComponent
            output = "Selected: \(selectedFileName)\nPath: \(selectedFilePath)"
        case .failure(let error):
            output = "Selection error: \(error.localizedDescription)"
        }
    }

   private func startCarving() {
    guard !selectedFilePath.isEmpty else { return }
    isCarving = true
    output = "Starting JPEG carving...\n"

    Task {
        do {
            let startTime = CFAbsoluteTimeGetCurrent()
            try await performJPEGCarving(on: selectedFilePath)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime

            await MainActor.run {
                output += "Time elapsed: \(String(format: "%.2f", elapsed))s\n"
                output += "\n✓ JPEG carving complete!"
                isCarving = false
            }
        } catch {
            await MainActor.run {
                output = "Error: \(error.localizedDescription)"
                isCarving = false
            }
        }
    }
}

    private func performJPEGCarving(on filePath: String) async throws {
        let fileURL = URL(fileURLWithPath: filePath)
        output += "Attempting to open file: \(filePath)\n"

        // Try to access security-scoped resource if available (fileImporter may provide one)
        var startedAccess = false
        if fileURL.startAccessingSecurityScopedResource() {
            startedAccess = true
        }
        
        defer { if startedAccess { fileURL.stopAccessingSecurityScopedResource() } }

        // Read the entire file into memory as Data (required by JPEGExtractor APIs)
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw NSError(domain: "CarverError", code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "Cannot read file data: \(filePath)"])
        }

        let fileName = fileURL.lastPathComponent

        await MainActor.run { output += "File: \(fileName)\n" }

        guard let staticJpegExtractor = JPEGExtractor.shared else {
            throw NSError(domain: "CarverError", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "JPEGExtractor (Metal) not available"])
        }

        // Call extractor APIs with Data and collect offsets (await outside MainActor)
        let (headerOffsetsAll, footerOffsetsAll) = try await staticJpegExtractor.scan(data: fileData)

        var result = "\n--- JPEG CARVING RESULTS ---\n"
        if headerOffsetsAll.isEmpty && footerOffsetsAll.isEmpty {
            result += "No JPEG headers or footers found in the image.\n"
        } else {
            if !headerOffsetsAll.isEmpty {
                result += "Found \(headerOffsetsAll.count) JPEG header(s):\n"
                for h in headerOffsetsAll {
                    result += "JPEG HEADER at offset: \(h)\n"
                }
                result += "\n"
            } else {
                result += "No JPEG headers found\n"
            }

            if !footerOffsetsAll.isEmpty {
                result += "Found \(footerOffsetsAll.count) JPEG footer(s):\n"
                for f in footerOffsetsAll {
                    result += "JPEG FOOTER at offset: \(f)\n"
                }
            } else {
                result += "No JPEG footers found\n"
            }
        }

        await MainActor.run {
            self.output += result
        }
    }

    // NOTE: header detection is handled by `JPEGExtractor` (Metal GPU). Kept no-CPU fallback here.
}