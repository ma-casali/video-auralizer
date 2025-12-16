//
//  SpectrumCompute.metal
//  video-auralizer
//
//  Created by Matthew Casali on 12/9/25.
//
#include <metal_stdlib>
using namespace metal;

#define M_PI 3.14159265358979323846

struct SpectrumParams {
    float T;
    float Q_scaling;
    float spectrumMixing;
    float padding0;    // align to 16 bytes
    
    uint P;
    uint F;
    uint padding1;
    
    float hpCutoff;
    float lpCutoff;
    float hpOrder;
    float lpOrder;
    uint padding2;
};

// --- Complex helpers ---
inline float2 complexMul(float2 a, float2 b) {
    return float2(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x);
}

inline float2 complexDiv(float2 a, float2 b) {
    float denom = b.x*b.x + b.y*b.y + 1e-12; // avoid divide by zero
    return float2((a.x*b.x + a.y*b.y)/denom, (a.y*b.x - a.x*b.y)/denom);
}

inline float sinc(float x) {
    return (x == 0.0f) ? 1.0f : sin(M_PI * x) / (M_PI * x);
}

// --- Kernel ---
kernel void computeSpectrum(device const float* amplitudeFrame [[buffer(0)]],
                            device const float* f0Frame [[buffer(1)]],
                            device const float* frequencies [[buffer(2)]],
                            device const float2* previousSpectrum [[buffer(3)]],
                            device float2* totalSum [[buffer(4)]],
                            constant SpectrumParams& params [[buffer(5)]],
                            uint fIdx [[thread_position_in_grid]])
{
    if (fIdx >= params.F) return;
    
    float freq = frequencies[fIdx];
    float2 sum = float2(0.0, 0.0);
    
    for (uint32_t p = 0; p < params.P; ++p) {
        float f0 = f0Frame[p];
        float A = amplitudeFrame[p];
        
        float diffPos = freq - f0;
        float diffNeg = freq + f0;
        
        float x0Pos = diffPos * params.T;
        float x1Pos = (diffPos - 1.0 / params.T) * params.T;
        float x2Pos = (diffPos + 1.0 / params.T) * params.T;

        float x0Neg = diffNeg * params.T;
        float x1Neg = (diffNeg - 1.0 / params.T) * params.T;
        float x2Neg = (diffNeg + 1.0 / params.T) * params.T;
        
        float WPos = (params.T/2) * sinc(x0Pos) - (params.T/4) * (sinc(x1Pos) + sinc(x2Pos));
        float WNeg = (params.T/2) * sinc(x0Neg) - (params.T/4) * (sinc(x1Neg) + sinc(x2Neg));
        
        float2 value = complexMul(float2(0.0, -0.5), float2(WPos - WNeg, 0.0));
        
        float Q = f0 / (A * 255.0) * params.Q_scaling;
        float2 denom = float2(1.0, Q * (freq - f0));
        float2 resonantPeak = complexDiv(float2(1.0, 0.0), denom);
        
        value = complexMul(value, resonantPeak);
        value = complexMul(value, float2(A, 0.0));
        
        sum += value;
    }
    
    // High-pass / low-pass filters
    if (freq <= params.hpCutoff) {
        float gain = 2.0 / (1.0 + pow((params.hpCutoff - freq), params.hpOrder));
        sum *= float2(gain, 0.0);
    }
    if (freq >= params.lpCutoff) {
        float gain = 2.0 / (1.0 + pow((freq - params.lpCutoff), params.lpOrder));
        sum *= float2(gain, 0.0);
    }
    
    // Mix with previous spectrum
    float2 prev = previousSpectrum[fIdx];
    totalSum[fIdx] = complexMul(float2(params.spectrumMixing, 0.0), prev) +
                     complexMul(float2(1.0 - params.spectrumMixing, 0.0), sum);
}
