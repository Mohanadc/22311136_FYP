//
//  JPEGKernal.metal
//  FYP_22311136
//
//  Created by Mohanad Magdi Mohamed on 19/02/2026.
//

#include <metal_stdlib>
using namespace metal;

kernel void searchJPEG(
    device const uchar* data     [[ buffer(0) ]],
    device atomic_uint* hits     [[ buffer(1) ]],  // packed: [offset, type, offset, type, ...]
    device atomic_uint* hitCount [[ buffer(2) ]],
    constant uint&      dataSize [[ buffer(3) ]],
    uint id [[ thread_position_in_grid ]]
)
{
    if (id >= dataSize) return;

    uchar b0 = data[id];
    if (b0 != 0xFF) return; // fast exit — avoids 99%+ of threads doing extra work

    if (id + 2 < dataSize) {
        // JPEG header: FF D8 FF
        if (data[id + 1] == 0xD8 && data[id + 2] == 0xFF) {
            uint slot = atomic_fetch_add_explicit(hitCount, 2, memory_order_relaxed);
            atomic_store_explicit(&hits[slot],     id, memory_order_relaxed);
            atomic_store_explicit(&hits[slot + 1], 0,  memory_order_relaxed); // 0 = header
        }
    }

    if (id + 1 < dataSize) {
        // JPEG footer: FF D9
        if (data[id + 1] == 0xD9) {
            uint slot = atomic_fetch_add_explicit(hitCount, 2, memory_order_relaxed);
            atomic_store_explicit(&hits[slot],     id, memory_order_relaxed);
            atomic_store_explicit(&hits[slot + 1], 1,  memory_order_relaxed); // 1 = footer
        }
    }
}