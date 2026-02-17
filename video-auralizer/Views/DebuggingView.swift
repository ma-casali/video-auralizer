import SwiftUI
import UIKit
import CoreGraphics

struct ConvolutionDebugView: View {
    @ObservedObject var converter: VideoConverter
    @StateObject private var camera = CameraModel()
    
    @State private var selectedMode = 0 // 0: Breathing, 1: V-Tilt, 2: H-Tilt, 3: Saddle
    @State private var selectedChannel: Int = 0 // 0: Hue, 1: Saturation, 2: Intensity

    var body: some View {
        VStack {
            // Channel Selector
            Picker("Channel", selection: $selectedChannel) {
                Text("Hue").tag(0)
                Text("Saturation").tag(1)
                Text("Intensity").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            
            // Mode Selector (Gradients)
            Picker("Gradient Mode", selection: $selectedMode) {
                Text("Breathing").tag(0)
                Text("V-Tilt").tag(1)
                Text("H-Tilt").tag(2)
                Text("Saddle").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            GeometryReader { geo in
                let currentData = getCurrentData()
                
                if !currentData.isEmpty && converter.debugSize.width > 0 {
                    ZStack {
                        // 1. The Per-Pixel Heatmap
                        HeatmapView(data: currentData,
                                    size: converter.debugSize,
                                    mode: selectedMode)
                        
                        // 2. The 4x4 Numerical Overlay
                        if !converter.cellAvgGrads.isEmpty {
                            GridOverlay(grads: converter.cellAvgGrads, mode: selectedMode)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .background(Color.black)
                    .cornerRadius(12)
                    .clipped()
                } else {
                    VStack(spacing: 20) {
                        ProgressView()
                        Text("Waiting for GPU Data...")
                            .foregroundColor(.secondary)
                        Text("Buffers: H:\(converter.debugHue.count) S:\(converter.debugSaturation.count) I:\(converter.debugIntensity.count)")
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()

            // The Peak Hue Matrix at the bottom
            DebugMatrix(peaks: converter.cellMaxHues)
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                camera.startSession()
                converter.attachToSession(camera.session)
            }
        }
    }
    
    // Helper to pick the correct buffer based on the picker
    private func getCurrentData() -> [SIMD4<Float>] {
        switch selectedChannel {
        case 0: return converter.debugHue
        case 1: return converter.debugSaturation
        case 2: return converter.debugIntensity
        default: return []
        }
    }
}

// MARK: - Heatmap View (Per-Pixel)
struct HeatmapView: View {
    let data: [SIMD4<Float>]
    let size: CGSize
    let mode: Int // 0, 1, 2, 3

    var body: some View {
        Canvas { context, drawSize in
            // Use texture dimensions (rotated as per your kernel)
            let w = Int(size.height)
            let h = Int(size.width)
            let cellW = drawSize.width / CGFloat(w)
            let cellH = drawSize.height / CGFloat(h)
            
            for y in 0..<h {
                for x in 0..<w {
                    let idx = y * w + x
                    guard idx < data.count else { continue }
                    
                    let vec = data[idx]
                    // Extract val based on selected Mode
                    let val: Float = {
                        switch mode {
                        case 0: return vec.x
                        case 1: return vec.y
                        case 2: return vec.z
                        default: return vec.w
                        }
                    }()
                    
                    // Normalize for visual representation (clamped to 0...1)
                    let normalized = CGFloat(min(abs(val), 1.0))
                    let color = val >= 0 ? Color.green.opacity(normalized) : Color.red.opacity(normalized)
                    
                    let rect = CGRect(x: CGFloat(x) * cellW, y: CGFloat(y) * cellH, width: cellW, height: cellH)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}

// MARK: - Grid Overlay (Per-Cell Numerical)
struct GridOverlay: View {
    let grads: [SIMD4<Float>]
    let mode: Int
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { col in
                        let index = row * 4 + col
                        if index < grads.count {
                            let vec = grads[index]
                            let val = (mode == 0 ? vec.x : (mode == 1 ? vec.y : (mode == 2 ? vec.z : vec.w)))
                            
                            ZStack {
                                // Cell border
                                Rectangle()
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                
                                // Numerical Value
                                Text(String(format: "%.2f", val))
                                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white)
                                    // Shadow ensures readability against light heatmap colors
                                    .shadow(color: .black, radius: 3)
                                    .shadow(color: .black, radius: 1)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Peak Matrix (The Hue Display)
struct DebugMatrix: View {
    let peaks: [Int?]
    
    var body: some View {
        VStack(spacing: 2) {
            if !peaks.isEmpty {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<4, id: \.self) { col in
                            CellView(hueBin: peaks[row * 4 + col])
                        }
                    }
                }
            } else {
                Text("No Hue Data")
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.8))
        .cornerRadius(12)
        .padding(.bottom)
    }
}

struct CellView: View {
    let hueBin: Int?
    
    var body: some View {
        let bin = hueBin ?? 999
        let color = bin > 360 ? Color.gray.opacity(0.3) : Color(hue: Double(bin) / 360.0, saturation: 1, brightness: 1)
        let label = bin > 360 ? "-" : "\(bin)"
        
        Rectangle()
            .fill(color)
            .frame(width: 45, height: 45)
            .cornerRadius(4)
            .overlay(
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(radius: 1)
            )
    }
}
