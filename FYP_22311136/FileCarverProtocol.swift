import Foundation

/// Common interface for file carving implementations.
///
/// Both `GpuFileCarver` and `CpuFileCarver` conform to this protocol,
/// allowing the UI to swap scanning strategies without changing the
/// carving/validation/saving pipeline.
protocol FileCarver {
    /// Human-readable name for this carver (e.g. "GPU", "CPU").
    var name: String { get }

    /// Scan the file at `url` for the specified `fileTypes` and return
    /// an array of header/footer `Match` pairs.
    func scanFile(url: URL, fileTypes: Set<FileType>) async throws -> [Match]
}
