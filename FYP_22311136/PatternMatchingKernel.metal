#include <metal_stdlib>
using namespace metal;

constant uint NODE_SIZE    = 257;
constant uint NULL_NODE    = 0xFFFFFFFF;
constant uint NO_MATCH     = 0;
constant uint MATCH_HEADER = 1;
constant uint MATCH_FOOTER = 2;

kernel void pfacScan(
    device const uchar*  data      [[ buffer(0) ]],
    device       uint*   hits      [[ buffer(1) ]],
    device atomic_uint*  hitCount  [[ buffer(2) ]],
    constant     uint&   dataSize  [[ buffer(3) ]],
    constant     uint&   maxHits   [[ buffer(4) ]],
    device const uint*   trie      [[ buffer(5) ]],
    uint id [[ thread_position_in_grid ]]
)
{
    // each thread is responsible for one starting position
    // if our position is beyond the data exit immediately
    if (id >= dataSize) return;

    uint currentNode = 0; // start at root

    for (uint i = id; i < dataSize; i++) {

        // read the byte at this position
        uchar byte = data[i];

        // look up the child slot for this byte in the current node
        uint childSlot = currentNode * NODE_SIZE + byte;
        uint childNode = trie[childSlot];

        // no edge for this byte — no match possible from id
        if (childNode == NULL_NODE) return;

        // follow the edge to the child node
        currentNode = childNode;

        // check the match slot of the node we just arrived at
        uint matchType = trie[currentNode * NODE_SIZE + 256];

        if (matchType != NO_MATCH) {
            // atomically claim two slots in the hits buffer
            uint hitIndex = atomic_fetch_add_explicit(
                hitCount,
                2,
                memory_order_relaxed
            );

            // only write if within the allocated buffer
            if (hitIndex + 1 < maxHits) {
                hits[hitIndex]     = id;        // pattern started at id
                hits[hitIndex + 1] = matchType; // 1 = header, 2 = footer
            }

            // one match per starting position — stop
            return;
        }
    }
}