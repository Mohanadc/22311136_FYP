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

    private let JPEG_HEADER: [UInt8] = [0xFF, 0xD8, 0xFF]
    private let JPEG_FOOTER: [UInt8] = [0xFF, 0xD9]

    static let shared: JPEGExtractor? = {
        do {
            return try JPEGExtractor()
        } catch {
            print("JPEGExtractor init failed: \(error)")
            return nil
        }
    }()

    // initialising metal environment

    let device: MTLDevice // GPU device
    let commandQueue: MTLCommandQueue // queue for sending commands to GPU
    let library: MTLLibrary // compiled GPU functions (shaders)
    let pipeline: MTLComputePipelineState // compiled state for the compute shader

    init() throws {

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw JPEGExtractorError.noDevice
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw JPEGExtractorError.commandQueueUnavailable
        }
        self.commandQueue = commandQueue

        guard let library = device.makeDefaultLibrary() else {
            throw JPEGExtractorError.libraryNotFound
        }
        self.library = library

        guard let function = library.makeFunction(name: "searchPattern") else {
            throw JPEGExtractorError.functionNotFound
        }

        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw JPEGExtractorError.pipelineError(error)
        }
    }
    //after initialisation we now have acces to the GPU, command queue, compiled shaders library and compiled searchpattern kernel.

    func findHeaderOffsets(in data: Data) async throws -> [Int] {
        return try await findOffsets(in: data, signature: JPEG_HEADER)
    }

    func findFooterOffsets(in data: Data) async throws -> [Int] {
        return try await findOffsets(in: data, signature: JPEG_FOOTER)
    }

    private func findOffsets(in data: Data, signature: [UInt8]) async throws -> [Int] {
        let byteArray = [UInt8](data)
        let bufCount = byteArray.count
        let signatureLen = signature.count

        guard let dataBuf = device.makeBuffer(bytes: byteArray, length: byteArray.count, options: []) else {
            throw JPEGExtractorError.bufferCreationFailed
        }
        guard let resultBuf = device.makeBuffer(length: bufCount * MemoryLayout<UInt32>.stride, options: []) else {
            throw JPEGExtractorError.bufferCreationFailed
        }

        guard let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            throw JPEGExtractorError.commandQueueUnavailable
        }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(dataBuf, offset: 0, index: 0)
        enc.setBuffer(resultBuf, offset: 0, index: 1)
        enc.setBytes(signature, length: signatureLen * MemoryLayout<UInt8>.stride, index: 2)
        var sigLen = UInt32(signatureLen)
        enc.setBytes(&sigLen, length: MemoryLayout<UInt32>.stride, index: 3)


        let maxThreads = max(1, bufCount - (signatureLen - 1))
        let threads = MTLSize(width: maxThreads, height: 1, depth: 1)
        let groupWidth = min(pipeline.maxTotalThreadsPerThreadgroup, 32)
        let threadsPerGroup = MTLSize(width: max(groupWidth, 1), height: 1, depth: 1)

        enc.dispatchThreads(threads, threadsPerThreadgroup: threadsPerGroup)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        
        let resultPointer = resultBuf.contents().bindMemory(to: UInt32.self, capacity: bufCount)
        var offsets = [Int]()
        for i in 0..<bufCount {
            if resultPointer[i] != 0 {
                offsets.append(i)
            }
        }
        return offsets
    }
}