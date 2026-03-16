import Foundation

/// Static utility for pairing header and footer offsets into file matches.
/// Shared by both GPU and CPU carvers so the matching logic is identical
/// and benchmarks measure only the scanning speedup.
enum SignatureMatcher {

    /// Pair sorted header offsets with their nearest following footer offset.
    ///
    /// Algorithm: for each header, find the first footer that comes *after* it.
    /// Once a footer is consumed by a header it is not reused.
    ///
    /// - Parameters:
    ///   - headers: Sorted array of absolute header offsets.
    ///   - footers: Sorted array of absolute footer offsets.
    /// - Returns: Array of `Match` values with paired header/footer offsets.
    static func pairHeadersWithFooters(
        headers: [Int],
        footers: [Int]
    ) -> [Match] {
        var matches: [Match] = []
        var footerIndex = 0

        for header in headers {
            // Advance past any footers that are at or before this header
            while footerIndex < footers.count && footers[footerIndex] <= header {
                footerIndex += 1
            }
            guard footerIndex < footers.count else { break }
            matches.append(Match(
                fileType: .jpeg,
                headerOffset: header,
                footerOffset: footers[footerIndex]
            ))
            footerIndex += 1
        }

        return matches
    }
}
