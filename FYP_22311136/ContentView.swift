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
            Text("JPEG Carver — 1MB buffered reader")
                .font(.headline)

            if selectedFileName.isEmpty {
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

                    Button("Change") { isSelectingFile = true }
                }
                .padding()
            }

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
        guard !selectedFilePath.isEmpty else {
            output = "No file selected"
            return
        }
        isCarving = true
        output = "Starting JPEG carving...\n"

        Task {
            do {
                try await performJPEGCarving(on: selectedFilePath)
                await MainActor.run {
                    isCarving = false
                    output += "\n✓ JPEG carving complete!"
                }
            } catch {
                await MainActor.run {
                    isCarving = false
                    output = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    // Reads the file in 1MB buffers and finds JPEG headers (FF D8 FF) like the C++ template
    private func performJPEGCarving(on filePath: String) async throws {
        let fileURL = URL(fileURLWithPath: filePath)

        // Try to access security-scoped resource if available (fileImporter may provide one)
        var startedAccess = false
        if fileURL.startAccessingSecurityScopedResource() {
            startedAccess = true
        }
        defer { if startedAccess { fileURL.stopAccessingSecurityScopedResource() } }

        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            throw NSError(domain: "CarverError", code: -3,
                         userInfo: [NSLocalizedDescriptionKey: "Cannot open file: \(filePath)"])
        }
        defer { try? fileHandle.close() }

        let fileName = fileURL.lastPathComponent
        let bufferSize = 1024 * 1024 // 1 MB
    var offset: Int64 = 0
    var headerOffsetsAll: [Int] = []
    var footerOffsetsAll: [Int] = []

        await MainActor.run { output += "File: \(fileName)\nBuffer size: 1 MB\n" }

        guard let extractor = JPEGExtractor.shared else {
            throw NSError(domain: "CarverError", code: -4,
                         userInfo: [NSLocalizedDescriptionKey: "JPEGExtractor (Metal) not available"])
        }

        while true {
            let buffer = fileHandle.readData(ofLength: bufferSize)
            guard !buffer.isEmpty else { break }

            // Use GPU extractor to find headers and footers in this chunk
            let headerOffsets = try await extractor.findHeaderOffsets(in: buffer)
            for headerOffset in headerOffsets {
                headerOffsetsAll.append(Int(offset) + headerOffset)
            }

            let footerOffsets = try await extractor.findFooterOffsets(in: buffer)
            for footerOffset in footerOffsets {
                footerOffsetsAll.append(Int(offset) + footerOffset)
            }

            // Show a small hex preview (first 512 bytes of this chunk) to aid debugging (optional)
            await MainActor.run {
                if self.showHexPreview {
                    let prefixCount = min(512, buffer.count)
                    let preview = buffer.prefix(prefixCount).map { String(format: "%02X", $0) }.joined(separator: " ")
                    output += "Chunk at offset \(offset):\n\(preview)\n...\n"
                }
            }

            offset += Int64(buffer.count)
            await MainActor.run { output += "Scanned \(offset / 1024 / 1024) MB...\n" }
        }

        await MainActor.run {
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
            self.output += result
        }
    }

    // NOTE: header detection is handled by `JPEGExtractor` (Metal GPU). Kept no-CPU fallback here.
}