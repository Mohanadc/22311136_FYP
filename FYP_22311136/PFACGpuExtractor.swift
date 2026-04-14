import Foundation
import Metal

final class PFACGpuExtractor: FileCarver {
    let name = "PFAC GPU"

    /// Factory-style accessor: returns a fresh extractor instance each time.
    /// This avoids keeping Metal device/pipeline objects pinned in memory
    /// for the entire app lifetime when not actively scanning.
    static var shared: PFACGpuExtractor? {
        do { return try PFACGpuExtractor() }
        catch { print("PFACGpuExtractor init failed: \(error)"); return nil }
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    static let chunkSize       = 64 * 1024 * 1024
    static let overlapSize     = 3
    static let maxHitsPerChunk = 131_072

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice()
        else { throw CarverError.noDevice }
        self.device = device

        guard let queue = device.makeCommandQueue()
        else { throw CarverError.commandQueueUnavailable }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary()
        else { throw CarverError.libraryNotFound }
        guard let function = library.makeFunction(name: "pfacScan")
        else { throw CarverError.functionNotFound }

        do { pipeline = try device.makeComputePipelineState(function: function) }
        catch { throw CarverError.pipelineError(error) }
    }

    // MARK: - FileCarver conformance

    func scanFile(url: URL, fileTypes: Set<FileType>) async throws -> [Match] {
        guard !fileTypes.isEmpty else { throw CarverError.noFileTypesSelected }

        guard let fileHandle = try? FileHandle(forReadingFrom: url)
        else { throw CarverError.fileReadError }
        defer { try? fileHandle.close() }

        let fileSize = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0

        // build trie once from all selected file types — reused across all chunks
        let activeSignatures = FileSignatures.all.filter { fileTypes.contains($0.type) }
        var signatureTrie = PFACTrie()
        for sig in activeSignatures {
            if !sig.header.isEmpty {
                signatureTrie.insert(pattern: sig.header, matchType: PFACTrie.matchTypeHeader)
            }
            if !sig.footer.isEmpty {
                signatureTrie.insert(pattern: sig.footer, matchType: PFACTrie.matchTypeFooter)
            }
        }

        var allHeaders: [Int] = []
        var allFooters: [Int] = []
        var fileOffset = 0

        while fileOffset < fileSize {
            let readSize  = min(Self.chunkSize + Self.overlapSize, fileSize - fileOffset)
            let chunkData = autoreleasepool { fileHandle.readData(ofLength: readSize) }
            if chunkData.isEmpty { break }

            let (headers, footers) = try await scanChunk(
                data: chunkData,
                signatureTrie: signatureTrie
            )

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

    // MARK: - Chunk scanning

    func scanChunk(data: Data, signatureTrie: PFACTrie) async throws -> (headers: [Int], footers: [Int]) {
        let dataSize = data.count
        let maxHits  = Self.maxHitsPerChunk * 2

        // MARK: Buffer creation — all buffers ready before command buffer is created

        // IMPORTANT: avoid `bytesNoCopy` with Data-backed memory here.
        // `Data` storage can be reclaimed/moved after `withUnsafeBytes` returns,
        // while GPU execution is still in flight, which leads to unstable memory
        // behavior that often looks like leaks/corruption in profiling.
        // Creating a copied MTLBuffer gives Metal-owned storage with a safe lifetime.
        guard let dataBuffer = data.withUnsafeBytes({ ptr -> MTLBuffer? in
            guard let base = ptr.baseAddress, dataSize > 0 else { return nil }
            return device.makeBuffer(bytes: base, length: dataSize, options: .storageModeShared)
        }) else { throw CarverError.bufferCreationFailed }

        guard let hitsBuffer = device.makeBuffer(
            length: maxHits * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { throw CarverError.bufferCreationFailed }

        guard let countBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { throw CarverError.bufferCreationFailed }

        guard let trieBuffer = device.makeBuffer(
            bytes: signatureTrie.flattened,
            length: signatureTrie.flattened.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else { throw CarverError.bufferCreationFailed }

        // zero the hit counter before dispatch
        countBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var dataSizeU32 = UInt32(dataSize)
        var maxHitsU32  = UInt32(maxHits)

        // MARK: Command encoding

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else { throw CarverError.commandQueueUnavailable }

        enc.setComputePipelineState(pipeline)
        enc.setBuffer(dataBuffer,  offset: 0, index: 0)
        enc.setBuffer(hitsBuffer,  offset: 0, index: 1)
        enc.setBuffer(countBuffer, offset: 0, index: 2)
        enc.setBytes(&dataSizeU32, length: MemoryLayout<UInt32>.stride, index: 3)
        enc.setBytes(&maxHitsU32,  length: MemoryLayout<UInt32>.stride, index: 4)
        enc.setBuffer(trieBuffer,  offset: 0, index: 5)

        let threadsPerGrid  = MTLSize(width: dataSize, height: 1, depth: 1)
        let threadsPerGroup = MTLSize(
            width: min(pipeline.maxTotalThreadsPerThreadgroup, 1024),
            height: 1,
            depth: 1
        )

        enc.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
        enc.endEncoding()

        // MARK: Completion

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

    private func parseHits(hitsBuffer: MTLBuffer, count: Int) -> (headers: [Int], footers: [Int]) {
        let ptr = hitsBuffer.contents().assumingMemoryBound(to: UInt32.self)

        var headers: [Int] = []
        var footers: [Int] = []

        // count/2 because each hit = 2 UInt32s (offset + matchType)
        let safeCount = min(count / 2, Self.maxHitsPerChunk)
        for i in 0..<safeCount {
            let offset    = Int(ptr[i * 2])
            let matchType = Int(ptr[i * 2 + 1])
            if matchType == 1 { headers.append(offset) }
            if matchType == 2 { footers.append(offset) }
        }

        headers.sort()
        footers.sort()
        return (headers, footers)
    }
}