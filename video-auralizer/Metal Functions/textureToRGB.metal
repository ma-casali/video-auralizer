//
//  textureToRGB.metal
//  video-auralizer
//
//  Created by Matthew Casali on 12/20/25.
//

#include <metal_stdlib>
using namespace metal;

kernel void textureToRGB(
                         texture2d<float, access::read> inTexture [[texture(0)]],
                         device float3* rgbOut [[buffer(0)]],
                         constant uint& width [[buffer(1)]],
                         constant uint& height [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]
                         ){
    uint x = gid.x;
    uint y = gid.y;
    
    if (x >= width || y >= height) return;
    
    uint idx = y * width + x;
    
    // Read normalized RGBA [0,1]
    float4 rgba = inTexture.read(uint2(x, y));
    
    // Store RGB only
    rgbOut[idx] = rgba.rgb;
}
