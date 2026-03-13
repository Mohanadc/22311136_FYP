import Foundation
import Metal

enum ExtractorError: Error {
    case noDevice
    case libraryNotFound
    case functionNotFound
    case pipelineError(Error)
    case commandQueueUnavailable
    case bufferCreationFailed
    case fileReadError
    case noFileTypesSelected
}

enum FileType: UInt32 {
    case jpeg = 0
}

struct FileSignature {
    let type: FileType
    let header: [UInt8]
    let footer: [UInt8]
}

// Represents a matched file type with header/footer offsets in absolute file coordinates
struct Match {
    let fileType: FileType
    let headerOffset: Int
    let footerOffset: Int
}

final class Extractor {

    static let shared: Extractor? = {
        do { return try Extractor() }
        catch { print("Extractor init failed: \(error)"); return nil }
    }()

    // 64MB chunks — fits comfortably in GPU memory, large enough to amortise overhead
    static let chunkSize = 64 * 1024 * 1024

    // Overlap ensures markers straddling chunk boundaries are never missed
    static let overlapSize  = 3

    // Hard cap on hits per chunk — 64MB / 3 bytes per hit worst case ~= 22M, but
    // realistically a few thousand. 1MB of hit slots = 256k UInt32 values = 128k hits.
    static let maxHitsPerChunk = 131_072 // 128k hits per chunk

    static let signatures: [FileSignature] = [
       .init(type: .jpeg, header: [0xFF, 0xD8, 0xFF], footer: [0xFF, 0xD9])
]

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState



    init() throws {
        guard let device = MTLCreateSystemDefaultDevice()
        else { throw ExtractorError.noDevice }
        self.device = device

        guard let queue = device.makeCommandQueue()
        else { throw ExtractorError.commandQueueUnavailable }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary()
        else { throw ExtractorError.libraryNotFound }   
        guard let function = library.makeFunction(name: "searchJPEG")
        else { throw ExtractorError.functionNotFound }

        do { pipeline = try device.makeComputePipelineState(function: function) }
        catch { throw ExtractorError.pipelineError(error) }
    }

    // ── Public entry point: streams a file in chunks ───────────────────────────

    func scanFile(url: URL, at fileTypes: Set<FileType>) async throws -> [Match] {
        if(fileTypes.isEmpty) {
            throw ExtractorError.noFileTypesSelected
        }
        guard let fileHandle = try? FileHandle(forReadingFrom: url)
        else { throw ExtractorError.fileReadError }
        defer { try? fileHandle.close() }

        let fileSize = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0

        var allHeaders: [Int] = []
        var allFooters: [Int] = []
        var fileOffset = 0

        while fileOffset < fileSize {
            // Read chunk + overlap so markers at boundaries are not split
            let readSize   = min(Self.chunkSize + Self.overlapSize, fileSize - fileOffset)
            let chunkData  = fileHandle.readData(ofLength: readSize)
            if chunkData.isEmpty { break }

            let (headers, footers) = try await scan(data: chunkData)

            // Translate chunk-relative offsets to absolute file offsets,
            // but skip anything that falls inside the overlap region of the
            // PREVIOUS chunk (i.e. offset < overlapSize when fileOffset > 0)
            // to avoid duplicates.
            let minOffset = fileOffset == 0 ? 0 : Self.overlapSize

            for h in headers where h >= minOffset {
                allHeaders.append(fileOffset + h)
            }
            for f in footers where f >= minOffset {
                allFooters.append(fileOffset + f)
            }

            // Advance by chunkSize only — the overlap bytes get re-read next iteration
            fileOffset += Self.chunkSize
        }

        return pairHeadersWithFooters(headers: allHeaders, footers: allFooters)
    }

    // ── Pairs sorted headers with their nearest following footer ───────────────

    private func pairHeadersWithFooters(
        headers: [Int],
        footers: [Int]
    ) -> [Match] {
        var matches: [Match] = []
        var footerIndex = 0

        for header in headers {
            // Find the first footer that comes after this header
            while footerIndex < footers.count && footers[footerIndex] <= header {
                footerIndex += 1
            }
            guard footerIndex < footers.count else { break }
            matches.append(Match(fileType: .jpeg, headerOffset: header, footerOffset: footers[footerIndex]))
            footerIndex += 1
        }

        return matches
    }

    // ── Single chunk scan — unchanged logic, capped buffer sizes ──────────────

    func scan(data: Data) async throws -> (headers: [Int], footers: [Int]) {
        let dataSize = data.count
        let maxHits  = Self.maxHitsPerChunk * 2 // *2 because each hit = (offset + type)

        guard let dataBuffer: MTLBuffer = data.withUnsafeBytes({ ptr in
            guard let base = ptr.baseAddress else { return nil }
            return device.makeBuffer(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                length: dataSize,
                options: .storageModeShared,
                deallocator: nil
            )
        }) else { throw ExtractorError.bufferCreationFailed }

        guard let hitsBuffer = device.makeBuffer(
            length: maxHits * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { throw ExtractorError.bufferCreationFailed }

        guard let countBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { throw ExtractorError.bufferCreationFailed }

        countBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var dataSizeU32 = UInt32(dataSize)
        // Pass the cap to the shader so it stops writing if the buffer is full
        var maxHitsU32  = UInt32(maxHits)

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { throw ExtractorError.commandQueueUnavailable }

        enc.setComputePipelineState(pipeline)
        enc.setBuffer(dataBuffer,  offset: 0, index: 0)
        enc.setBuffer(hitsBuffer,  offset: 0, index: 1)
        enc.setBuffer(countBuffer, offset: 0, index: 2)
        enc.setBytes(&dataSizeU32, length: MemoryLayout<UInt32>.stride, index: 3)
        enc.setBytes(&maxHitsU32,  length: MemoryLayout<UInt32>.stride, index: 4)

        let threadsPerGrid  = MTLSize(width: dataSize, height: 1, depth: 1)
        let threadsPerGroup = MTLSize(
            width: min(pipeline.maxTotalThreadsPerThreadgroup, 1024),
            height: 1, depth: 1
        )
        enc.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        enc.endEncoding()

        return try await withCheckedThrowingContinuation { continuation in
            cmd.addCompletedHandler { [hitsBuffer, countBuffer] _ in
                let count   = Int(countBuffer.contents().load(as: UInt32.self))
                let hitsPtr = hitsBuffer.contents().assumingMemoryBound(to: UInt32.self)

                var headers: [Int] = []
                var footers: [Int] = []

                let safeCount = min(count / 2, Self.maxHitsPerChunk)
                for i in 0..<safeCount {
                    let offset = Int(hitsPtr[i * 2])
                    let type   = Int(hitsPtr[i * 2 + 1])
                    if type == 0 { headers.append(offset) }
                    else         { footers.append(offset) }
                }

                headers.sort()
                footers.sort()
                continuation.resume(returning: (headers, footers))
            }
            cmd.commit()
        }
    }
}