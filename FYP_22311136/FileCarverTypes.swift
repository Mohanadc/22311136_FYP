import Foundation

// MARK: - Errors

/// Errors that can occur during file carving operations
enum CarverError: Error {
    case noDevice
    case libraryNotFound
    case functionNotFound
    case pipelineError(Error)
    case commandQueueUnavailable
    case bufferCreationFailed
    case fileReadError
    case noFileTypesSelected
}

// MARK: - File Type

/// Supported file types and their numeric IDs (used by the GPU shader)
enum FileType: UInt32, CaseIterable, Hashable {
    case jpeg = 0
}

// MARK: - File Signature

/// A file signature containing header and footer byte sequences
struct FileSignature {
    let type: FileType
    let header: [UInt8]
    let footer: [UInt8]
}

// MARK: - Match

/// Represents a matched file with header/footer offsets in absolute file coordinates
struct Match {
    let fileType: FileType
    let headerOffset: Int
    let footerOffset: Int
}

// MARK: - Known Signatures

/// Central registry of known file signatures
enum KnownSignatures {
    static let all: [FileSignature] = [
        .init(type: .jpeg, header: [0xFF, 0xD8, 0xFF], footer: [0xFF, 0xD9])
    ]
}
