import Foundation

/// CPU-only file carver — sequential, single-threaded byte-by-byte scanner.
///
/// This serves as the **baseline** for measuring GPU speedup.
/// No Metal, no GCD, no concurrency — pure sequential scanning.
final class CpuFileCarver: FileCarver {

    let name = "CPU"
    
    static let shared: CpuFileCarver? = { do { return try CpuFileCarver() } catch { print("CpuFileCarver init failed: \(error)"); return nil } }()
    // Use the same chunking constants as the GPU carver for a fair comparison
    static let chunkSize    = 64 * 1024 * 1024   // 64 MB
    static let overlapSize  = 3                    // data of overlap between chunks

    func scanFile(url: URL, fileTypes: Set<FileType>) async throws -> [Match] {
        guard !fileTypes.isEmpty else {
            throw CarverError.noFileTypesSelected
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            throw CarverError.fileReadError
        }
        defer { try? fileHandle.close() }

        let fileSize = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0

        // Collect the signatures we need to scan for
        let activeSignatures = FileSignatures.all.filter { fileTypes.contains($0.type) }
        print("Active signatures: \(activeSignatures)")
        var allHeaders: [Int] = []
        var allFooters: [Int] = []
        var fileOffset = 0

        while fileOffset < fileSize {
            let readSize  = min(Self.chunkSize + Self.overlapSize, fileSize - fileOffset)
            let chunkData = fileHandle.readData(ofLength: readSize)
            if chunkData.isEmpty { break }

            let data = [UInt8](chunkData)
            let (headers, footers) = scanChunk(data: data, signatures: activeSignatures)

            // Translate chunk-relative offsets to absolute file offsets,
            // skipping anything in the overlap region of the PREVIOUS chunk
            let minOffset = fileOffset == 0 ? 0 : Self.overlapSize

            for h in headers where h >= minOffset {
                allHeaders.append(fileOffset + h)
            }
            for f in footers where f >= minOffset {
                allFooters.append(fileOffset + f)
            }

            fileOffset += Self.chunkSize
        }

        return SignatureMatcher.pairHeadersWithFooters(
            headers: allHeaders,
            footers: allFooters
        )
    }

    // MARK: - Sequential byte scan

    /// Scan a single chunk of data sequentially for header and footer markers.
    ///
    /// This is the hot path that the GPU replaces with massively-parallel execution.
    /// Intentionally kept single-threaded for a clean baseline measurement.
    private func scanChunk(
        data: [UInt8],
        signatures: [FileSignature]
    ) -> (headers: [Int], footers: [Int]) {
        var headers: [Int] = []
        var footers: [Int] = []
        let count = data.count

        for sig in signatures {
            print("Scanning for signature: \(sig)")
            let headerLen = sig.header.count
            let footerLen = sig.footer.count

            // Scan for headers
            if headerLen > 0 {
                let limit = count - headerLen
                for i in 0...limit {
                    var matched = true
                    for j in 0..<headerLen {
                        if data[i + j] != sig.header[j] {
                            matched = false
                            break
                        }
                    }
                    if matched {
                        headers.append(i)
                    }
                }
            }

            // Scan for footers
            if footerLen > 0 {
                let limit = count - footerLen
                for i in 0...limit {
                    var matched = true
                    for j in 0..<footerLen {
                        if data[i + j] != sig.footer[j] {
                            matched = false
                            break
                        }
                    }
                    if matched {
                        footers.append(i)
                    }
                }
            }
        }
        return (headers, footers)
    }
}
