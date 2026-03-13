import SwiftUI
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Metal

struct ContentView: View {
    @State private var output: String = "Ready to carve JPEG files"
    @State private var isSelectingFile = false
    @State private var selectedFilePath: String = ""
    @State private var selectedFileName: String = ""
    @State private var isCarving = false
    @State private var finishedCarving = false
    @State private var savedFileURLs: [URL] = []

    // Available file types to display; populate from your supported signatures
    @State private var fileTypes: [FileType] = [.jpeg]
    // User-selected file types to scan
    @State private var selectedFileTypes: Set<FileType> = [.jpeg]

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
                        Label(startButtonLabel, systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(startButtonDisabled)

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
                    Text("File types to scan")
                        .font(.headline)
                    ForEach(fileTypes, id: \.self) { type in
                        Toggle(label(for: type), isOn: Binding(
                            get: { selectedFileTypes.contains(type) },
                            set: { isOn in
                                if isOn { selectedFileTypes.insert(type) }
                                else { selectedFileTypes.remove(type) }
                            }
                        ))
                    }
                }
                .padding()
                .background(.thickMaterial)
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
        guard !startButtonDisabled else { output = startButtonLabel; return }
        isCarving = true
        savedFileURLs = []
        finishedCarving = false
    output = "Starting carving for: \(selectedFileTypesText)\n"

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

        await MainActor.run { output += "File: \(fileURL.lastPathComponent)\n" }

        guard let extractor = Extractor.shared else {
            throw NSError(domain: "CarverError", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Extractor (Metal) not available"])
        }

        // ── Scan (streaming) ───────────────────────────────────────────────────
        // Use the URL-based streaming scan to avoid loading the whole file into memory.
        let matches = try await extractor.scanFile(url: fileURL, at: selectedFileTypes)

        await MainActor.run {
            output += "Found \(matches.count) JPEG(s)\n\n--- CARVING ---\n"
        }

        if matches.isEmpty {
            await MainActor.run { output += "No JPEGs found in image.\n" }
            return
        }

        // ── Extract, validate (decode), and save each JPEG (read slices from disk) ─
        var urls: [URL] = []
        var lastSavedEnd: Int = -1

        // Open a FileHandle once for reading carved ranges
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            throw NSError(domain: "CarverError", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot open file for reading: \(filePath)"])
        }
        defer { try? fileHandle.close() }

        for (index, match) in matches.enumerated() {
            let header = match.headerOffset
            let footer = match.footerOffset

            // footer points to the FF D9 marker — the JPEG ends 2 bytes after it
            let end = footer + 2

            // Ensure the requested range is valid with respect to file size
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = fileAttributes[.size] as? Int ?? 0
            guard header < end, end <= fileSize else {
                await MainActor.run {
                    output += "[\(index)] Skipped — invalid range \(header)..<\(end)\n"
                }
                continue
            }

            if lastSavedEnd >= 0 && header < lastSavedEnd {
                await MainActor.run {
                    output += "[\(index)] NOTE — header overlaps previous saved JPEG (header: \(header) < lastSavedEnd: \(lastSavedEnd)). Will attempt validation and save if it decodes.\n"
                }
            }

            // Read the exact bytes from disk by seeking and reading the range
            try fileHandle.seek(toOffset: UInt64(header))
            let length = end - header
            let jpegData = fileHandle.readData(ofLength: length)

            // Quick marker-level sanity check: starts with FF D8 and ends with FF D9
            let bytes = [UInt8](jpegData)
            if bytes.count < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8 || bytes[bytes.count - 2] != 0xFF || bytes[bytes.count - 1] != 0xD9 {
                await MainActor.run {
                    output += "[\(index)] SKIPPED — marker sanity check failed (missing SOI/EOI)\n"
                }
                continue
            }

            // Try to decode the bytes with Image I/O to ensure it's a valid image
            var decodedOK = false
            if let src = CGImageSourceCreateWithData(jpegData as CFData, nil) {
                if CGImageSourceGetCount(src) > 0,
                   let _ = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    decodedOK = true
                }
            }

            if !decodedOK {
                await MainActor.run {
                    output += "[\(index)] SKIPPED — failed to decode carved bytes as an image\n"
                }
                continue
            }

            let outputURL = outputFolder.appendingPathComponent("carved_\(index).jpg")
            do {
                try jpegData.write(to: outputURL, options: .atomic)
                urls.append(outputURL)
                await MainActor.run {
                    output += "[\(index)] Saved \(jpegData.count) bytes → carved_\(index).jpg\n"
                    output += "     Header: 0x\(String(header, radix: 16, uppercase: true))"
                    output += "  Footer: 0x\(String(footer, radix: 16, uppercase: true))\n"
                }
                lastSavedEnd = end
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

    private func label(for type: FileType) -> String {
        switch type {
        case .jpeg: return "JPEG"
        }
    }

    private var selectedFileTypesText: String {
        if selectedFileTypes.isEmpty { return "None" }
        return selectedFileTypes.map(label(for:)).sorted().joined(separator: ", ")
    }

    private var startButtonLabel: String {
    if isCarving { return "Carving…" }
    if finishedCarving { return "Select another file to carve." }
    if selectedFileTypes.isEmpty { return "Please select file types to begin carving." }
    return "Start Carving"
    }

    private var startButtonDisabled: Bool {
        selectedFilePath.isEmpty || isCarving || finishedCarving || selectedFileTypes.isEmpty
    }

    // MARK: - Testable helpers
    // Static, pure helpers mirror the instance logic and are easy to unit test.
    static func startButtonLabel(isCarving: Bool, finishedCarving: Bool, selectedFileTypesEmpty: Bool) -> String {
        if isCarving { return "Carving…" }
        if finishedCarving { return "Select another file to carve." }
        if selectedFileTypesEmpty { return "Select file types" }
        return "Start Carving"
    }

    static func isStartButtonDisabled(selectedFilePathEmpty: Bool, isCarving: Bool, finishedCarving: Bool, selectedFileTypesEmpty: Bool) -> Bool {
        selectedFilePathEmpty || isCarving || finishedCarving || selectedFileTypesEmpty
    }

    static func isRevealButtonDisabled(savedFileURLsEmpty: Bool, isCarving: Bool) -> Bool {
        savedFileURLsEmpty || isCarving
    }

    static func selectButtonLabel(selectedFileNameEmpty: Bool) -> String {
        selectedFileNameEmpty ? "Select" : "Change"
    }

    static func isClearVisible(isCarving: Bool) -> Bool {
        !isCarving
    }


}
