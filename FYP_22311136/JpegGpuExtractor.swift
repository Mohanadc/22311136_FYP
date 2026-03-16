import Foundation
import Metal

/// Metal-backed file carver that scans data in chunks using GPU compute shaders.
///
/// All shared types (`CarverError`, `FileType`, `Match`, etc.) live in
/// `FileCarverTypes.swift`. Pair-matching is handled by `SignatureMatcher`.
final class GpuFileCarver: FileCarver {

    let name = "GPU"

    static let shared: GpuFileCarver? = {
        do { return try GpuFileCarver() }
        catch { print("GpuFileCarver init failed: \(error)"); return nil }
    }()

    // Chunking and buffer sizing constants used for GPU scanning
    // 64MB chunks — fits comfortably in GPU memory, large enough to amortise overhead
    static let chunkSize = 64 * 1024 * 1024

    // Overlap ensures markers straddling chunk boundaries are never missed
    static let overlapSize  = 3

    // Hard cap on hits per chunk — bounds GPU buffer size and host processing work
    // 1MB of hit slots = 256k UInt32 values = 128k hits.
    static let maxHitsPerChunk = 131_072 // 128k hits per chunk

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    // Initialize Metal device, create command queue and compile the compute pipeline
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice()
        else { throw CarverError.noDevice }
        self.device = device

        guard let queue = device.makeCommandQueue()
        else { throw CarverError.commandQueueUnavailable }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary()
        else { throw CarverError.libraryNotFound }
        guard let function = library.makeFunction(name: "searchJPEG")
        else { throw CarverError.functionNotFound }

        do { pipeline = try device.makeComputePipelineState(function: function) }
        catch { throw CarverError.pipelineError(error) }
    }

    // MARK: - FileCarver conformance

    /// Stream the file in fixed-size chunks, run GPU scan on each chunk,
    /// and return absolute header/footer offsets found across the file.
    func scanFile(url: URL) async throws -> [Match] {
        guard let fileHandle = try? FileHandle(forReadingFrom: url)
        else { throw CarverError.fileReadError }
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

        return SignatureMatcher.pairHeadersWithFooters(
            headers: allHeaders,
            footers: allFooters
        )
    }

    // MARK: - GPU scanning

    /// Run the Metal compute shader on a single data chunk and return the
    /// header/footer offsets that the GPU identified (chunk-local offsets).
    func scan(data: Data) async throws -> (headers: [Int], footers: [Int]) {
        let dataSize = data.count
        let maxHits  = Self.maxHitsPerChunk * 2 // *2 because each hit = (offset + type)

        // Create GPU buffers:
        // - dataBuffer shares the chunk data with the GPU without copying
        // - hitsBuffer is where the GPU writes found offsets and types (UInt32 pairs)
        // - countBuffer is a single UInt32 that the GPU atomically increments for each hit
        guard let dataBuffer: MTLBuffer = data.withUnsafeBytes({ ptr in
            guard let base = ptr.baseAddress else { return nil }
            return device.makeBuffer(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                length: dataSize,
                options: .storageModeShared,
                deallocator: nil
            )
        }) else { throw CarverError.bufferCreationFailed }

        guard let hitsBuffer = device.makeBuffer(
            length: maxHits * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { throw CarverError.bufferCreationFailed }

        guard let countBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { throw CarverError.bufferCreationFailed }

        countBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var dataSizeU32 = UInt32(dataSize)
        // Pass the cap to the shader so it stops writing if the buffer is full
        var maxHitsU32  = UInt32(maxHits)

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { throw CarverError.commandQueueUnavailable }

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
                let count = Int(countBuffer.contents().load(as: UInt32.self))
                let (headers, footers) = self.parseHits(hitsBuffer: hitsBuffer, count: count)
                continuation.resume(returning: (headers, footers))
            }
            cmd.commit()
        }
    }

    // MARK: - Hit parsing

    /// Parse the raw GPU hits buffer into sorted header/footer offset arrays.
    private func parseHits(hitsBuffer: MTLBuffer, count: Int) -> (headers: [Int], footers: [Int]) {
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
        return (headers, footers)
    }
}