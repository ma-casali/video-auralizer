//
//  convolveFeatures.metal
//  video-auralizer
//
//  Created by Matthew Casali on 2/11/26.
//

#include <metal_stdlib>
using namespace metal;

#define M_PI 3.14159265358979323846

// CONVERT RGB to HSI
float3 rgb_to_hsi(float3 rgb) {
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;
    
    // 1. Intensity
    float I = (r + g + b) / 3.0f;
    
    // 2. Saturation
    float min_val = min(r, min(g, b));
    float S = (I > 0.0f) ? (1.0f - min_val / I) : 0.0f;
    
    // 3. Hue
    float H = 0.0f;
    float num = 0.5f * ((r - g) + (r - b));
    float den = sqrt((r - g) * (r - g) + (r - b) * (g - b));
    
    if (den != 0.0f) {
        float theta = acos(num / den); // Returns [0, PI]
        H = (b <= g) ? theta : (2.0f * M_PI_F - theta);
        H /= (2.0f * M_PI_F); // Normalize to [0, 1]
    }
    
    return float3(H, S, I);
}

kernel void convolveFeatures(
                             texture2d<float, access::sample> inputTexture [[texture(0)]],
                             device     float4* hueMap          [[buffer(0)]],
                             device     float4* saturationMap   [[buffer(1)]],
                             device     float4* intensityMap    [[buffer(2)]],
                             device     float3* rawHSIMap       [[buffer(6)]],
                             
                             constant   uint&   mipWidth        [[buffer(3)]],
                             constant   uint&   mipHeight       [[buffer(4)]],
                             constant   uint&   mipLevel        [[buffer(5)]],
                                        uint2   gid             [[thread_position_in_grid]]) {
    
    // BOUNDARY CHECKS
    uint rotatedX = (mipHeight - 1) - gid.y;
    uint rotatedY = gid.x;

    // Exit if out of bounds for this mip level
    if (rotatedY >= mipWidth || rotatedX >= mipHeight) return;

    uint idx = rotatedY * mipHeight + rotatedX;
    
    // SETUP SAMPLER
    sampler texSampler(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5f) / float2(mipWidth, mipHeight);
    float2 texelSize = 1.0f / float2(mipWidth, mipHeight);
    
    // GATHER ALL 9 PIXELS
    float3 i00 = rgb_to_hsi(inputTexture.sample(texSampler, uv + texelSize * float2(-1,-1), level(mipLevel)).rgb); // Top-Left
    float3 i10 = rgb_to_hsi(inputTexture.sample(texSampler, uv + texelSize * float2( 0,-1), level(mipLevel)).rgb); // Top-Center
    float3 i20 = rgb_to_hsi(inputTexture.sample(texSampler, uv + texelSize * float2( 1,-1), level(mipLevel)).rgb); // Top-Right
    
    float3 i01 = rgb_to_hsi(inputTexture.sample(texSampler, uv + texelSize * float2(-1, 0), level(mipLevel)).rgb); // Mid-Left
    float3 i11 = rgb_to_hsi(inputTexture.sample(texSampler, uv + texelSize * float2( 0, 0), level(mipLevel)).rgb); // Center
    float3 i21 = rgb_to_hsi(inputTexture.sample(texSampler, uv + texelSize * float2( 1, 0), level(mipLevel)).rgb); // Mid-Right
    
    float3 i02 = rgb_to_hsi(inputTexture.sample(texSampler, uv + texelSize * float2(-1, 1), level(mipLevel)).rgb); // Bottom-Left
    float3 i12 = rgb_to_hsi(inputTexture.sample(texSampler, uv + texelSize * float2( 0, 1), level(mipLevel)).rgb); // Bottom-Center
    float3 i22 = rgb_to_hsi(inputTexture.sample(texSampler, uv + texelSize * float2( 1, 1), level(mipLevel)).rgb); // Bottom-Right
    
    // Hue Matrix
    float4 cA = float4(i00.x, i10.x, i20.x, i01.x);
    float4 cB = float4(i21.x, i02.x, i12.x, i22.x);
    float cC = i11.x;
    
    // Saturation Matrix
    float4 pA = float4(i00.y, i10.y, i20.y, i01.y);
    float4 pB = float4(i21.y, i02.y, i12.y, i22.y);
    float pC = i11.y;
    
    // Intensity Matrix
    float4 iA = float4(i00.z, i10.z, i20.z, i01.z);
    float4 iB = float4(i21.z, i02.z, i12.z, i22.z);
    float iC = i11.z;
    
    // CONVOLUTIONAL MASKS (must sum to 0)
    // Breathing Mode
    float4 bA = float4(-1,  0, -1,  0);
    float4 bB = float4( 0, -1,  0, -1);
    float bC = 4.0;
    
    // Vertical Tilt Mode
    float4 vA = float4( 1,  0, -1,  1);
    float4 vB = float4(-1,  1,  0, -1);
    float vC = 0.0;
    
    // Horizontal Tilt Mode
    float4 hA = float4(-1, -1, -1,  0);
    float4 hB = float4( 0,  1,  1,  1);
    float hC = 0.0;
    
    // Saddle Mode
    float4 sA = float4( 1,  0, -1,  0);
    float4 sB = float4( 0, -1,  0,  1);
    float sC = 0.0;
    
    // CONVOLUTIONAL MATH
    hueMap[idx].x = dot(cA, bA) + dot(cB, bB) + cC * bC;
    hueMap[idx].y = dot(cA, vA) + dot(cB, vB) + cC * vC;
    hueMap[idx].z = dot(cA, hA) + dot(cB, hB) + cC * hC;
    hueMap[idx].w = dot(cA, sA) + dot(cB, sB) + cC * sC;
    
    saturationMap[idx].x = dot(pA, bA) + dot(pB, bB) + pC * bC;
    saturationMap[idx].y = dot(pA, vA) + dot(pB, vB) + pC * vC;
    saturationMap[idx].z = dot(pA, hA) + dot(pB, hB) + pC * hC;
    saturationMap[idx].w = dot(pA, sA) + dot(pB, sB) + pC * sC;
    
    intensityMap[idx].x = dot(iA, bA) + dot(iB, bB) + iC * bC;
    intensityMap[idx].y = dot(iA, vA) + dot(iB, vB) + iC * vC;
    intensityMap[idx].z = dot(iA, hA) + dot(iB, hB) + iC * hC;
    intensityMap[idx].w = dot(iA, sA) + dot(iB, sB) + iC * sC;
}

kernel void calculateHueHistogram(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    device atomic_uint* histogram [[buffer(0)]],
    constant uint& mipWidth [[buffer(1)]],
    constant uint& mipHeight [[buffer(2)]],
    constant uint& mipLevel  [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    // BOUNDARY CHECKS
    uint rotatedX = (mipHeight - 1) - gid.y;
    uint rotatedY = gid.x;
    
    sampler texSampler(filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5f) / float2(mipWidth, mipHeight);
    float3 mipTexture = inputTexture.sample(texSampler, uv, level(mipLevel)).rgb;

    // Exit if out of bounds for this mip level
    if (rotatedY >= mipWidth || rotatedX >= mipHeight) return;

    float3 hsi = rgb_to_hsi(mipTexture); // Use your existing conversion
    
    // Only count pixels with enough color (Saturation) to be a "subject"
    if (hsi.y > 0.0 && hsi.z > 0.1) {
        uint col = (rotatedX * 4) / mipHeight;
        uint row = (rotatedY * 4) / mipWidth;
        uint cellIdx = row * 4 + col;
        
        uint hueBin = uint(hsi.x * 359.0);
        
        uint globalBinIdx = (cellIdx * 360) + hueBin;
        
        atomic_fetch_add_explicit(&histogram[globalBinIdx], 1, memory_order_relaxed);
    }
}
