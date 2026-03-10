import Foundation
import Metal

enum JPEGExtractorError: Error {
    case noDevice
    case libraryNotFound
    case functionNotFound
    case pipelineError(Error)
    case commandQueueUnavailable
    case bufferCreationFailed
}

final class JPEGExtractor {

    static let shared: JPEGExtractor? = {
        do { return try JPEGExtractor() }
        catch { print("JPEGExtractor init failed: \(error)"); return nil }
    }()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice()
        else { throw JPEGExtractorError.noDevice }
        self.device = device

        guard let queue = device.makeCommandQueue()
        else { throw JPEGExtractorError.commandQueueUnavailable }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary()
        else { throw JPEGExtractorError.libraryNotFound }

        guard let function = library.makeFunction(name: "searchJPEG")
        else { throw JPEGExtractorError.functionNotFound }

        do { pipeline = try device.makeComputePipelineState(function: function) }
        catch { throw JPEGExtractorError.pipelineError(error) }
    }

    // ── Single pass: returns both headers and footers at once ──────────────────
    
    private func findHeaderOffsets(in data: Data) async throws -> [Int] {
        let (headers, _) = try await scan(data: data)
        return headers
    }

    private func findFooterOffsets(in data: Data) async throws -> [Int] {
        let (_, footers) = try await scan(data: data)
        return footers
    }

    func scan(data: Data) async throws -> (headers: [Int], footers: [Int]) {
        let dataSize = data.count
        // Upper bound: can't have more hits than bytes, but realistically far fewer.
        // 1 hit per 3 bytes is extremely generous.
        let maxHits  = max((dataSize / 3) * 2, 128) // *2 because each hit = (offset + type)

        // ── Buffers ────────────────────────────────────────────────────────────

        // Zero-copy on Apple Silicon: GPU and CPU share the same physical memory
        let dataBuffer: MTLBuffer? = data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return nil }
            return device.makeBuffer(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                length: dataSize,
                options: .storageModeShared,
                deallocator: nil
            )
        }
        guard let dataBuffer else { throw JPEGExtractorError.bufferCreationFailed }

        // hits buffer: [offset0, type0, offset1, type1, ...]
        guard let hitsBuffer = device.makeBuffer(
            length: maxHits * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { throw JPEGExtractorError.bufferCreationFailed }

        guard let countBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { throw JPEGExtractorError.bufferCreationFailed }

        // Zero the counter
        countBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var dataSizeU32 = UInt32(dataSize)

        // ── Encode ─────────────────────────────────────────────────────────────

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { throw JPEGExtractorError.commandQueueUnavailable }

        enc.setComputePipelineState(pipeline)
        enc.setBuffer(dataBuffer,  offset: 0, index: 0)
        enc.setBuffer(hitsBuffer,  offset: 0, index: 1)
        enc.setBuffer(countBuffer, offset: 0, index: 2)
        enc.setBytes(&dataSizeU32, length: MemoryLayout<UInt32>.stride, index: 3)

        // One thread per byte, 1024 threads per group
        let threadsPerGrid      = MTLSize(width: dataSize, height: 1, depth: 1)
        let threadsPerGroup     = MTLSize(
            width: min(pipeline.maxTotalThreadsPerThreadgroup, 1024),
            height: 1, depth: 1
        )
        enc.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        enc.endEncoding()

        // ── Async completion — no thread blocking ──────────────────────────────

        return try await withCheckedThrowingContinuation { continuation in
            cmd.addCompletedHandler { [hitsBuffer, countBuffer] _ in
                let count = Int(countBuffer.contents().load(as: UInt32.self))
                let hitsPtr = hitsBuffer.contents()
                    .assumingMemoryBound(to: UInt32.self)

                var headers: [Int] = []
                var footers: [Int] = []

                let safeCount = min(count, maxHits / 2) // each hit = 2 slots
                for i in 0..<safeCount {
                    let offset = Int(hitsPtr[i * 2])
                    let type   = Int(hitsPtr[i * 2 + 1])
                    if type == 0 { headers.append(offset) }
                    else         { footers.append(offset) }
                }

                // GPU threads complete out of order — sort for correct output
                headers.sort()
                footers.sort()

                continuation.resume(returning: (headers, footers))
            }
            cmd.commit()
        }
    }
}