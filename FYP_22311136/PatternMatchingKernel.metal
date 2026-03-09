//
//  JPEGKernal.metal
//  FYP_22311136
//
//  Created by Mohanad Magdi Mohamed on 19/02/2026.
//

#include <metal_stdlib>
using namespace metal;

kernel void searchPattern(
    device const uchar* data [[buffer(0)]],
    device uint* results [[buffer(1)]],
    device const uchar* pattern [[buffer(2)]],
    device const uint& patternLength [[buffer(3)]],
    uint id [[thread_position_in_grid]]
)
{
    bool match = true;
    for (uint i = 0; i < patternLength; i++) {
        if (data[id + i] != pattern[i]) {
            match = false;
            break;
        }
    }
    results[id] = match ? 1 : 0;
}