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
    @State private var savedFileURLs: [URL] = []

    var body: some View {
        VStack(spacing: 12) {
            Text("JPEG Carver")
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
                        .fileImporter(
                            isPresented: $isSelectingFile,
                            allowedContentTypes: [.item],
                            onCompletion: handleSelection
                        )
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

            // Show a "Reveal in Finder" button once files have been saved
            if !savedFileURLs.isEmpty && !isCarving {
                Button(action: revealInFinder) {
                    Label("Reveal Carved JPEGs in Finder", systemImage: "folder")
                        .padding(8)
                }
                .foregroundColor(.blue)
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
            savedFileURLs = []
            output = "Selected: \(selectedFileName)\nPath: \(selectedFilePath)"
        case .failure(let error):
            output = "Selection error: \(error.localizedDescription)"
        }
    }

    private func startCarving() {
        guard !selectedFilePath.isEmpty else { return }
        isCarving = true
        savedFileURLs = []
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

    // Opens the output folder in Finder so the user can see their carved files
    private func revealInFinder() {
        guard let first = savedFileURLs.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([first])
    }

    private func performJPEGCarving(on filePath: String) async throws {
        let fileURL = URL(fileURLWithPath: filePath)
        await MainActor.run { output += "Attempting to open file: \(filePath)\n" }

        var startedAccess = false
        if fileURL.startAccessingSecurityScopedResource() {
            startedAccess = true
        }
        defer { if startedAccess { fileURL.stopAccessingSecurityScopedResource() } }

        // ── Prepare output folder ─────────────────────────────────────────────
        // Creates a subfolder named after the source file inside ~/Documents/CarvedJPEGs/
        // e.g. ~/Documents/CarvedJPEGs/disk_image/carved_0.jpg
        let outputFolder = try makeOutputFolder(for: fileURL)
        await MainActor.run { output += "Output folder: \(outputFolder.path)\n" }

        // ── Read file ─────────────────────────────────────────────────────────
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            throw NSError(domain: "CarverError", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot read file: \(filePath)"])
        }

        await MainActor.run { output += "File: \(fileURL.lastPathComponent)\n" }

        guard let extractor = JPEGExtractor.shared else {
            throw NSError(domain: "CarverError", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "JPEGExtractor (Metal) not available"])
        }

        // ── Scan ──────────────────────────────────────────────────────────────
        let matches = try await extractor.scanFile(at: fileURL)

        await MainActor.run {
            output += "Found \(matches.count) JPEG(s)\n\n--- CARVING ---\n"
        }

        if matches.isEmpty {
            await MainActor.run { output += "No JPEGs found in image.\n" }
            return
        }

        // ── Extract and save each JPEG ────────────────────────────────────────
        var urls: [URL] = []

        for (index, match) in matches.enumerated() {
            let header = match.headerOffset
            let footer = match.footerOffset

            // footer points to the FF D9 marker — the JPEG ends 2 bytes after it
            let end = footer + 2

            guard header < end, end <= fileData.count else {
                await MainActor.run {
                    output += "[\(index)] Skipped — invalid range \(header)..<\(end)\n"
                }
                continue
            }

            // Slice the exact bytes from header to end of footer marker
            let jpegData = fileData[header..<end]

            let outputURL = outputFolder
                .appendingPathComponent("carved_\(index).jpg")

            do {
                try jpegData.write(to: outputURL, options: .atomic)
                urls.append(outputURL)
                await MainActor.run {
                    output += "[\(index)] Saved \(jpegData.count) bytes → carved_\(index).jpg\n"
                    output += "     Header: 0x\(String(header, radix: 16, uppercase: true))"
                    output += "  Footer: 0x\(String(footer, radix: 16, uppercase: true))\n"
                }
            } catch {
                await MainActor.run {
                    output += "[\(index)] Failed to write: \(error.localizedDescription)\n"
                }
            }
        }

        await MainActor.run {
            savedFileURLs = urls
            output += "\nSaved \(urls.count) file(s) to:\n\(outputFolder.path)\n"
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// Creates ~/Documents/CarvedJPEGs/<source file stem>/ and returns its URL.
    private func makeOutputFolder(for sourceURL: URL) throws -> URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first!

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let folder = documents
            .appendingPathComponent("CarvedJPEGs")
            .appendingPathComponent(stem)

        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        return folder
    }
}