//
//  JPEGKernal.metal
//  FYP_22311136
//
//  Created by Mohanad Magdi Mohamed on 19/02/2026.
//

#include <metal_stdlib>
using namespace metal;

kernel void findJPEGHeaders(
    device const uchar* data [[buffer(0)]],
    device uint* results [[buffer(1)]],
    uint id [[thread_position_in_grid]]
)
{
    if (id == 0) { results[id] = 0; return; }
    results[id] = (data[id-1] == 0xFF && data[id] == 0xD8) ? 1 : 0;
}
