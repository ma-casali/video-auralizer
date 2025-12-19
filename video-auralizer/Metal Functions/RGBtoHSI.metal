//
//  RGBtoHSI.metal
//  video-auralizer
//
//  Created by Matthew Casali on 12/18/25.
//

#include <metal_stdlib>
using namespace metal;

float3 rgb_to_hsi(float3 rgb)
{
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;

    float I = (r + g + b) / 3.0;

    float minRGB = min(r, min(g, b));
    float S = (I > 0.0) ? 1.0 - (minRGB / I) : 0.0;

    float num = 0.5 * ((r - g) + (r - b));
    float den = sqrt((r - g)*(r - g) + (r - b)*(g - b)) + 1e-6;
    float theta = acos(clamp(num / den, -1.0, 1.0));

    float H = (b <= g) ? theta : (2.0 * M_PI_F - theta);
    H /= (2.0 * M_PI_F); // normalize to [0,1]

    return float3(H, S, I);
}

