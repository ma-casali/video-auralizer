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
    float frameSeed;
    
    uint P;
    uint F;
    float binWidth;
    float padding1;
    
    float hpCutoff;
    float lpCutoff;
    float hpOrder;
    float lpOrder;
};


// Finds the index of the value in 'freqs' closest to 'target'
uint find_closest_index(device const float* freqs, uint count, float target) {
    if (count == 0) return 0;
    int low = 0;
    int high = (int)count - 1; // Use signed int to prevent underflow
    
    while (low <= high) {
        int mid = low + (high - low) / 2;
        if (freqs[mid] < target) low = mid + 1;
        else if (freqs[mid] > target) high = mid - 1;
        else return (uint)mid;
    }
    
    if (low >= (int)count) return count - 1;
    if (low <= 0) return 0;
    
    return (abs(freqs[low] - target) < abs(freqs[low - 1] - target)) ? (uint)low : (uint)(low - 1);
}

// --- Complex helpers ---
inline float2 complexMul(float2 a, float2 b) {
    return float2(a.x*b.x - a.y*b.y, a.x*b.y + a.y*b.x);
}

inline float2 complexDiv(float2 a, float2 b) {
    float denom = b.x*b.x + b.y*b.y + 1e-12; // avoid divide by zero
    return float2((a.x*b.x + a.y*b.y)/denom, (a.y*b.x - a.x*b.y)/denom);
}

// --- Function Helpers ---
inline float sinc(float x) {
    return (x == 0.0f) ? 1.0f : sin(M_PI * x) / (M_PI * x);
}

// --- Normalized Bessel Zeros ---
constant float besselRatios[9] = {
    // j11 = 3.8317
    4.2012 / 3.8317, // j31
    5.3314 / 3.8317, // j12
    6.7061 / 3.8317, // j22
    7.0156 / 3.8317, // j02
    8.0152 / 3.8317, // j32
    8.5363 / 3.8317, // j13
    9.9695 / 3.8317, // j23
    10.1735 / 3.8317, // j03
    11.3459 / 3.8317, // j33
};

kernel void computeSpectrum(device const int* fundamentals [[buffer(0)]],
                            device const float4* grads [[buffer(1)]],
                            device const float* frequencies [[buffer(2)]],
                            device const float2* previousSpectrum [[buffer(3)]],
                            device const float* phaseAccum [[buffer(4)]],
                            device float2* totalSum [[buffer(5)]],
                            constant SpectrumParams& params [[buffer(6)]],
                            uint fIdx [[thread_position_in_grid]])
{
    if (fIdx >= params.F) return;
    
    float currentBinFreq = frequencies[fIdx];
    float2 currentFrameSum = float2(0.0);
    float hannMult = 1.0f / params.binWidth;
    
    float randomPhase = fract(sin(float(fIdx) * 12.9898f) * 43758.5453f) * 2.0f * M_PI_F;
    float2 staticPhaseVec = float2(cos(randomPhase), sin(randomPhase));

    // Iterate through the 16 cells
    for (uint cell = 0; cell < 16; ++cell) {
        int hueBin = fundamentals[cell];
        if (hueBin < 0 || hueBin > 360) continue;

        // 1. Map Hue to Logarithmic Frequency
        // Range: 55Hz to 3520Hz
//        float f0 = frequencies[5 + hueBin*3];
        float f0_raw = 220.0f * pow(2.0f, (float(hueBin) / 360.0f) * 3.0f); // 6 octaves total
        uint f0_ind = find_closest_index(frequencies, params.F, f0_raw);
        float f0 = frequencies[f0_ind];
        float bandWidth = (f0 < 200.0f) ? 5.0f : 1.0f;

        // 2. Extract Gradient Modes
        float breathingRMS = grads[cell].x; // Determines Roll-off
        float vTiltAbs    = grads[cell].y; // Weight Odd Harmonics
        float hTiltAbs    = grads[cell].z; // Weight Even Harmonics
        float saddlePeak  = grads[cell].w; // Strength of Bessel modes
        
        float2 cellAccum = float2(0.0);
        float totalCellGain = 0.0f;

        // Calculate Dynamic Roll-off (dB/octave)
        // 0.5 rollOff ~= 3 dB/oct
        float rollOffFactor = mix(4.0, 0.5, clamp(breathingRMS * 5.0f, 0.0f, 1.0f));
        if (!isfinite(rollOffFactor)) rollOffFactor = 2.0f;
        
        // 4. Integer Harmonics Loop
        for (int h = 1; h <= 13; ++h) {
            float hFreq = f0 * float(h);
            if (hFreq > 20000.0f) break;
            
            // --- NEW: Per-Harmonic Phase ---
            // Use the cell index, frequency index, and harmonic number to create a unique seed
            float hSeed = float(cell) * 1.618f + float(h) * 13.13f;
            float phaseVelocity = phaseAccum[cell*(13 + 9) + (h-1)];
            float hPhase = fract(sin(hSeed) * 43758.5453f) * 2.0f * M_PI + phaseVelocity;
            float2 hPhaseVec = float2(cos(hPhase), sin(hPhase));

            // Base gain with breathing-controlled roll-off
            float hGain = pow(float(h), -rollOffFactor);
            
            totalCellGain += hGain;
            
            if (h > 1) { // Apply only to harmonics
                float vWeight = 1.0f;
                float hWeight = 1.0f;

                // Even/Odd Weighting (V-Tilt vs H-Tilt)
                if (vTiltAbs == 0) {
                    vWeight = 0.0f;
                    hWeight = 1.0f;
                } else if (hTiltAbs == 0) {
                    vWeight = 1.0f;
                    hWeight = 0.0f;
                } else {
                    vWeight = vTiltAbs / max(hTiltAbs, vTiltAbs);
                    hWeight = hTiltAbs / max(hTiltAbs, vTiltAbs);
                }
                
                if (h % 2 == 0) hGain *= vWeight;
                else            hGain *= hWeight;
            }

            // Windowed Sine accumulation
            float diff = (currentBinFreq - hFreq) * hannMult / bandWidth;
            float W = 0.5f * sinc(diff) - 0.25f * (sinc(diff - 1.0f) + sinc(diff + 1.0f));
            cellAccum += hPhaseVec * W * hGain; // Scale down to prevent clipping
        }

        // 5. Inharmonic Bessel Modes (Saddle Mode)
        // This adds the "metallic" Neumann membrane character
        for (int b = 0; b < 8; ++b) {
            float bFreq = f0 * besselRatios[b];
            if (bFreq > 20000.0f) break;
            
            // --- NEW: Per-Harmonic Phase ---
            // Use the cell index, frequency index, and harmonic number to create a unique seed
            float bSeed = float(cell) * 1.618f + float(b) * 13.13f;
            float phaseVelocity = phaseAccum[cell*(13+9) + b];
            float bPhase = fract(sin(bSeed) * 43758.5453f) * 2.0f * M_PI + phaseVelocity;
            float2 bPhaseVec = float2(cos(bPhase), sin(bPhase));

            float bGain = clamp(saddlePeak, 0.00f, 2.0f) * pow(besselRatios[b], -rollOffFactor);
            
            totalCellGain += bGain;

            float diff = (currentBinFreq - bFreq) * hannMult / bandWidth;
            float W = 0.5f * sinc(diff) - 0.25f * (sinc(diff - 1.0f) + sinc(diff + 1.0f));
            cellAccum += bPhaseVec * W * bGain;
        }
        
        float frequencyCompensation = sqrt(f0 / 220.0f);
        float norm = 1.0f / max(totalCellGain, 0.001f);
        norm *= 0.0625f; // 1/16
        currentFrameSum += cellAccum * norm * frequencyCompensation;
    }
    
    currentFrameSum *= staticPhaseVec;

//    // 6. Filtering & Temporal Smoothing
//    float filterGain = 1.0;
//    if (currentBinFreq <= params.hpCutoff) {
//        filterGain /= (1.0 + pow(max(0.0f, (params.hpCutoff - currentBinFreq)), params.hpOrder));
//    }
//    if (currentBinFreq >= params.lpCutoff) {
//        filterGain /= (1.0 + pow(max(0.0f, (currentBinFreq - params.lpCutoff)), params.lpOrder));
//    }
//    
//    currentFrameSum *= filterGain;
//    
    // Mix with previous frame to prevent clicking/jitter
    float2 prev = previousSpectrum[fIdx];
    totalSum[fIdx] = mix(prev, currentFrameSum, 1.0f - params.spectrumMixing);
}
