import SwiftUI
import Metal

struct ContentView: View {
    var body: some View {
        Text("Check console for output")
            .padding()
            .onAppear {
                testMetalJPEG()
            }
    }
}

func testMetalJPEG() {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("No GPU found")
        return
    }

    guard let library = device.makeDefaultLibrary() else {
        print("Failed to load Metal library")
        return
    }

    guard let fn = library.makeFunction(name: "findJPEGHeaders") else {
        print("Failed to get kernel function")
        return
    }

    let pipeline: MTLComputePipelineState
    do {
        pipeline = try device.makeComputePipelineState(function: fn)
    } catch {
        print("Pipeline error: \(error)")
        return
    }

    guard let queue = device.makeCommandQueue() else {
        print("Failed to create command queue")
        return
    }

    // Example file bytes (replace with your file data later)
    let fileBytes: [UInt8] = [0x00, 0xFF, 0xD8, 0x11, 0xFF, 0xD8]
    let size = fileBytes.count

    let dataBuf = device.makeBuffer(bytes: fileBytes, length: size)!
    let resultBuf = device.makeBuffer(length: size * MemoryLayout<UInt32>.stride)!

    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeComputeCommandEncoder()!

    enc.setComputePipelineState(pipeline)
    enc.setBuffer(dataBuf, offset: 0, index: 0)
    enc.setBuffer(resultBuf, offset: 0, index: 1)

    let threads = MTLSize(width: size, height: 1, depth: 1)
    let groupWidth = min(pipeline.maxTotalThreadsPerThreadgroup, 32)
    let threadsPerGroup = MTLSize(width: groupWidth, height: 1, depth: 1)

    enc.dispatchThreads(threads, threadsPerThreadgroup: threadsPerGroup)
    enc.endEncoding()

    cmd.commit()
    cmd.waitUntilCompleted()

    let results = resultBuf.contents().bindMemory(to: UInt32.self, capacity: size)
    for i in 0..<size where results[i] == 1 {
        print("JPEG header at byte index: \(i)")
    }
}
