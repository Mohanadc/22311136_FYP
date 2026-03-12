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
    @State private var finishedCarving = false
    @State private var showHexPreview: Bool = false
    @State private var savedFileURLs: [URL] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("JPEG Carver")
                        .font(.title2).bold()
                    Text("Select a disk image, scan for JPEGs, validate, and save them.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                // File card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "externaldrive")
                            .foregroundColor(.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedFileName.isEmpty ? "No file selected" : selectedFileName)
                                .font(.headline)
                            Text(selectedFilePath.isEmpty ? "Choose a raw image (.img/.dmg/.iso)" : selectedFilePath)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button(selectedFileName.isEmpty ? "Select" : "Change") {
                            isSelectingFile = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .background(.ultraThickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .fileImporter(
                    isPresented: $isSelectingFile,
                    allowedContentTypes: [.item],
                    onCompletion: handleSelection
                )

                // Actions row
                HStack(spacing: 12) {
                    Button(action: startCarving) {
                        Label(isCarving ? "Carving…" : finishedCarving ? "Select another file to carve." : "Start Carving", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(selectedFilePath.isEmpty || isCarving || finishedCarving)

                    Button(action: revealInFinder) {
                        Label("Reveal", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(savedFileURLs.isEmpty || isCarving)
                }

                if finishedCarving {
                    Text("Carving finished. Select another file to carve.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Status / progress
                if isCarving {
                    HStack {
                        ProgressView()
                        Text("Working… This may take a moment.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Options
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show hex preview (first 512 bytes)", isOn: $showHexPreview)
                }
                .padding()
                .background(.thickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Output / log
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Activity Log")
                            .font(.headline)
                        Spacer()
                        if !isCarving {
                            Button("Clear") { output = "" }
                                .font(.caption)
                        }
                    }
                    ScrollView {
                        Text(output)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .frame(minHeight: 220)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding()
        }
    }

    private func handleSelection(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            selectedFilePath = url.path
            selectedFileName = url.lastPathComponent
            savedFileURLs = []
            finishedCarving = false
            output = "Selected: \(selectedFileName)\nPath: \(selectedFilePath)"
        case .failure(let error):
            output = "Selection error: \(error.localizedDescription)"
        }
    }

    private func startCarving() {
        guard !selectedFilePath.isEmpty else { return }
        isCarving = true
        savedFileURLs = []
        finishedCarving = false
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
                    finishedCarving = true
                }
            } catch {
                await MainActor.run {
                    output = "Error: \(error.localizedDescription)"
                    isCarving = false
                    finishedCarving = false
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

            // ── Validate before saving ────────────────────────────────────────
            let validation = extractor.validateJPEG(data: Data(jpegData))
            if !validation.isValid {
                await MainActor.run {
                    output += "[\(index)] SKIPPED — failed validation: \(validation.reason)\n"
                    output += "     Header: 0x\(String(header, radix: 16, uppercase: true))"
                    output += "  Footer: 0x\(String(footer, radix: 16, uppercase: true))\n"
                }
                continue
            }

            let outputURL = outputFolder
                .appendingPathComponent("carved_\(index).jpg")

            do {
                try jpegData.write(to: outputURL, options: .atomic)
                urls.append(outputURL)
                await MainActor.run {
                    output += "[\(index)] ✓ \(validation.reason)\n"
                    output += "     Saved \(jpegData.count) bytes → carved_\(index).jpg\n"
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