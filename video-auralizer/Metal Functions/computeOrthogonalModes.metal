#include <metal_stdlib>
using namespace metal;

#define M_PI 3.14159265358979323846

struct Modes {
    float2 I_c;
    float2 S_c;
    float4 I;
    float4 S;
    float4 f0;
};

// Fused kernel: RGB → HSI → Orthogonal Modes (with mipmaps)
kernel void computeOrthogonalModesFromTexture(
    texture2d<float, access::sample> inTexture [[texture(0)]],
    device Modes*                    modeOut   [[buffer(0)]],
    constant uint&                   width     [[buffer(1)]],
    constant uint&                   height    [[buffer(2)]],
    constant uint&                   mipLevel  [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // --------------------------------------------------
    // Compute mip level dimensions
    // --------------------------------------------------
    uint mipWidth  = max(1u, width  >> mipLevel);
    uint mipHeight = max(1u, height >> mipLevel);

    uint x = gid.x;
    uint y = gid.y;

    // Exit if out of bounds for this mip level
    if (x >= mipWidth || y >= mipHeight) return;

    uint idx = y * mipWidth + x;

    // ----------------------------------------
    // Setup sampler for linear filtering
    // ----------------------------------------
    sampler texSampler(filter::linear, address::clamp_to_edge);

    // Helper: sample RGB at a given offset and mip level
    auto samplePixel = [&](int dx, int dy) -> float3 {
        int nx = clamp(int(x) + dx, 0, int(mipWidth) - 1);
        int ny = clamp(int(y) + dy, 0, int(mipHeight) - 1);
        float2 uv = (float2(nx, ny) + 0.5) / float2(mipWidth, mipHeight);
        return inTexture.sample(texSampler, uv, level(mipLevel)).rgb;
    };

    // ----------------------------------------
    // Sample center + neighbors
    // ----------------------------------------
    float3 rgbC = samplePixel(0, 0);
    float3 rgbN = samplePixel(0, -1);
    float3 rgbS = samplePixel(0,  1);
    float3 rgbE = samplePixel(1,  0);
    float3 rgbW = samplePixel(-1, 0);

    // ----------------------------------------
    // RGB → HSI conversion helper
    // ----------------------------------------
    auto computeHSI = [&](float3 rgb, thread float& I, thread float& S, thread float& f0) {
        float r = rgb.r;
        float g = rgb.g;
        float b = rgb.b;

        float sum = r + g + b;
        I = sum / 3.0;

        float mn = min(r, min(g, b));
        S = (sum > 1e-6f) ? 1.0f - (3.0f * mn / sum) : 0.0f;

        float num = 0.5f * ((r - g) + (r - b));
        float den = sqrt((r - g)*(r - g) + (r - b)*(g - b));
        float theta = (den > 1e-6f) ? acos(clamp(num / den, -1.0f, 1.0f)) : 0.0f;
        float H = (b <= g) ? theta : (2.0f * M_PI - theta);
        f0 = (390.0f / (2.0f * M_PI)) * H + 400.0f;
    };

    // ----------------------------------------
    // Compute HSI for center + neighbors
    // ----------------------------------------
    float I_c, S_c, f0_c;
    float I_N, S_N, f0_N;
    float I_S, S_S, f0_S;
    float I_E, S_E, f0_E;
    float I_W, S_W, f0_W;

    computeHSI(rgbC, I_c, S_c, f0_c);
    computeHSI(rgbN, I_N, S_N, f0_N);
    computeHSI(rgbS, I_S, S_S, f0_S);
    computeHSI(rgbE, I_E, S_E, f0_E);
    computeHSI(rgbW, I_W, S_W, f0_W);

    // ----------------------------------------
    // Relative differences
    // ----------------------------------------
    float dI_N = I_N - I_c;
    float dI_S = I_S - I_c;
    float dI_E = I_E - I_c;
    float dI_W = I_W - I_c;

    float dS_N = S_N - S_c;
    float dS_S = S_S - S_c;
    float dS_E = S_E - S_c;
    float dS_W = S_W - S_c;
    
    // ----------------------------------------
    // Compute orthogonal modes
    // ----------------------------------------
    const float invSqrt2 = 0.70710678f;

    float I_M1  = 0.5f      * (dI_N + dI_S + dI_E + dI_W);
    float I_M2  = invSqrt2 * (dI_N - dI_S);
    float I_M3  = invSqrt2 * (dI_E - dI_W);
    float I_M4  = 0.5f      * (dI_N - dI_E + dI_S - dI_W);

    float S_M1  = 0.5f      * (dS_N + dS_S + dS_E + dS_W);
    float S_M2  = invSqrt2 * (dS_N - dS_S);
    float S_M3  = invSqrt2 * (dS_E - dS_W);
    float S_M4  = 0.5f      * (dS_N - dS_E + dS_S - dS_W);

    // ----------------------------------------
    // Write output
    // ----------------------------------------
    modeOut[idx].I_c = float2(I_c, 0.0);
    modeOut[idx].S_c = float2(S_c, 0.0);
    modeOut[idx].I  = float4(I_M1,  I_M2,  I_M3,  I_M4);
    modeOut[idx].S  = float4(S_M1,  S_M2,  S_M3,  S_M4);
    modeOut[idx].f0 = float4(f0_c, f0_c, f0_c, f0_c);
}

