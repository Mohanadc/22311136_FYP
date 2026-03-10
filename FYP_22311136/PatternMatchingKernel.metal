#include <metal_stdlib>
using namespace metal;

kernel void searchJPEG(
    device const uchar* data      [[ buffer(0) ]],
    device atomic_uint* hits      [[ buffer(1) ]],
    device atomic_uint* hitCount  [[ buffer(2) ]],
    constant uint&      dataSize  [[ buffer(3) ]],
    constant uint&      maxHits   [[ buffer(4) ]],  // ← new
    uint id [[ thread_position_in_grid ]]
)
{
    if (id >= dataSize) return;

    uchar b0 = data[id];
    if (b0 != 0xFF) return;

    if (id + 2 < dataSize) {
        if (data[id + 1] == 0xD8 && data[id + 2] == 0xFF) {
            uint slot = atomic_fetch_add_explicit(hitCount, 2, memory_order_relaxed);
            // Only write if we're within the allocated buffer
            if (slot + 1 < maxHits) {
                atomic_store_explicit(&hits[slot],     id, memory_order_relaxed);
                atomic_store_explicit(&hits[slot + 1], 0,  memory_order_relaxed);
            }
        }
    }

    if (id + 1 < dataSize) {
        if (data[id + 1] == 0xD9) {
            uint slot = atomic_fetch_add_explicit(hitCount, 2, memory_order_relaxed);
            if (slot + 1 < maxHits) {
                atomic_store_explicit(&hits[slot],     id, memory_order_relaxed);
                atomic_store_explicit(&hits[slot + 1], 1,  memory_order_relaxed);
            }
        }
    }
}