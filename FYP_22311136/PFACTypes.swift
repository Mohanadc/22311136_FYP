import Foundation

struct PFACTrie {

    //flat array for the gpu to read
    // each node will occupy 257 slots
    // slots 0-255: child node indices for byte values 0-255 (255 = no child)
    // slot 256: file type ID if this node is a leaf, 0 if no match 1 if header 2 if footer
    private(set) var flattened: [UInt32] = []

    private var nodeCount: Int = 0

    static let nodeSize = 257
    static let nullNode: UInt32 = UInt32.max
    static let noMatch: UInt32 = 0
    static let matchTypeHeader: UInt32 = 1
    static let matchTypeFooter: UInt32 = 2

    init() {
        appendEmptyNode() // root node
    }

    @discardableResult
    private mutating func appendEmptyNode() -> Int {
        let nodeIndex = nodeCount

        flattened.append(contentsOf: Array(repeating: Self.nullNode, count: Self.nodeSize - 1)) // 256 child slots
        flattened.append(Self.noMatch) // default  to no match
        nodeCount += 1
        return nodeIndex
    }

    mutating func insert(pattern: [UInt8], matchType: UInt32) {
        guard !pattern.isEmpty else { return }

        var currentNode = 0 // start at root

        for byte in pattern {
            let childIndex = currentNode * Self.nodeSize + Int(byte)

            if(flattened[childIndex] == Self.nullNode) {
                // no child for this byte, create new node
                let newNodeIndex = appendEmptyNode()
                flattened[childIndex] = UInt32(newNodeIndex)
                currentNode = newNodeIndex
            } else {
                // child exists, move to it
                currentNode = Int(flattened[childIndex])
            }
            
        }
        flattened[currentNode * Self.nodeSize + 256] = matchType
    }




}