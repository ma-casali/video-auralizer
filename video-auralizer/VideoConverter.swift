import SwiftUI
import AVFoundation
import Metal
import MetalPerformanceShaders
import Combine
import simd

import simd

struct SpectrumParams {
    var T: Float
    var Q_scaling: Float
    var spectrumMixing: Float
    var padding0: Float = 0         // pad to align next UInt32
    
    var P: UInt32
    var F: UInt32
    var padding1: UInt32 = 0        // pad to 16 bytes
    
    var hpCutoff: Float
    var lpCutoff: Float
    var hpOrder: Float
    var lpOrder: Float
    var padding2: UInt32 = 0        // pad to 16 bytes
}


final class VideoConverter: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    @Published public var lastFrame: [Float] = []
    private var frameIndex: Int = 0
    private var audioFormat: AVAudioFormat!

    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var textureCache: CVMetalTextureCache!
    private var computePipeline: MTLComputePipelineState!
    
    // audio parameters
    private let sampleRate: Float32 = 44100.0
    private let videoFs: Float32 = 30.0
    private var N: Float
    private var F: Int
    private var original_f: [Float] = []
    private var f: [Float] = []
    private var outputSignal: [Float] = []
    
    // future controllable parameters
    @Published public var attack: Float32 = 0.1
    @Published public var release: Float32 = 0.01
    @Published public var spectrumMixing: Float32 = 0.5
    @Published public var Q_scaling: Float32 = 1.0
    @Published public var Hanning_Window_Multiplier: Float32 = 1.0
    @Published public var hpCutoff: Float32 = 20.0
    @Published public var lpCutoff: Float32 = 20_000.0
    @Published public var hpOrder: Float32 = 1.0
    @Published public var lpOrder: Float32 = 1.0
    @Published public var downSample: Int = 16
    
    // history parameters
    @Published public var previousSpectrum: [Complex]
    private var runningMax: Float = 0.0
    
    override init() {
        print("Initalizing VideoConverter...")
        self.N = floor(sampleRate / videoFs)
        print("N = \(self.N)")
        let F_float: Float32 = floor(N / 2)
        self.F = max(1, Int(F_float))
        self.previousSpectrum = [Complex](repeating: Complex(0,0), count: self.F)
        
        super.init()
        
        self.original_f = linspace(start: Float(self.F) / sampleRate, end: sampleRate / 2 + Float(self.F) / sampleRate, num: self.F)
        self.f = linearToLog2(self.original_f)
        self.outputSignal = [Float](repeating: 0.0, count: Int(self.N))

        loadFrequencyLUT()
        setupMetal()
        setupMetalCompute()
        setupAudio()
        
        print("Finished Initialization")
    }
    
    // MARK: - Attach to camera session
    func attachToSession(_ session: AVCaptureSession) {
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoConverterQueue"))
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
    }
    
    // MARK: - Metal Setup
    private func setupMetal() {
        device = MTLCreateSystemDefaultDevice()
        print("Metal device: \(String(describing: device))")
        commandQueue = device.makeCommandQueue()
        
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }
    
    // MARK: - Metal Compute Setup
    private func setupMetalCompute() {
        guard let library = device.makeDefaultLibrary() else {return}
        guard let kernel = library.makeFunction(name: "computeSpectrum") else { return }
        computePipeline = try? device.makeComputePipelineState(function: kernel)
    }
    
    // MARK: - Audio Setup
    private func setupAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            print("Audio session configured")
        } catch {
            print("Failed to configure audio session: \(error)")
        }
        
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        
        sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard !self.lastFrame.isEmpty else {
                // Fill with zeros if no frame yet
                for buffer in ablPointer {
                    memset(buffer.mData, 0, Int(frameCount) * MemoryLayout<Float>.size)
                }
                return noErr
            }
            
            for buffer in ablPointer {
                let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
                for frame in 0..<Int(frameCount) {
                    buf[frame] = self.lastFrame[self.frameIndex]
                    self.frameIndex += 1
                    if self.frameIndex >= self.lastFrame.count {
                        self.frameIndex = 0 // repeat last frame
                    }
                }
            }
            return noErr
        }
        
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)
        
        do {
            try audioEngine.start()
            print("Audio engine started")
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
    
    // MARK: - Capture Output
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Create Metal texture from pixel buffer
        var cvTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTextureOut
        )
        guard status == kCVReturnSuccess,
              let cvTexture = cvTextureOut,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return }
        
        processFrame(texture: texture)
        
    }
    
    // MARK: - GPU Frame Processing
    private let audioQueue = DispatchQueue(label: "audioQueue") // serialize audio buffer scheduling

    private func processFrame(texture: MTLTexture) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // --- GPU -> CPU copy ---
            let width = texture.width
            let height = texture.height
            let widthArray = Array(stride(from: 0, to: height, by: self.downSample))
            let heightArray = Array(stride(from: 0, to: width, by: self.downSample))
            let bytesPerRow = 4 * widthArray.count
            let pixelData = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * heightArray.count, alignment: 1)
            defer { pixelData.deallocate() }

            let region = MTLRegionMake2D(0, 0, widthArray.count, heightArray.count)
            texture.getBytes(pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

            // Extract RGB array
            var rgbArray: [(r: UInt8, g: UInt8, b: UInt8)] = []
            let ptr = pixelData.assumingMemoryBound(to: UInt8.self)
            for y in heightArray {
                let row = ptr + y * bytesPerRow
                for x in widthArray {
                    let pixel = row + x * 4
                    rgbArray.append((r: pixel[2], g: pixel[1], b: pixel[0]))
                }
            }

            // Generate amplitude and f0
            let eps: Float = 1e-9
            let amplitudeFrame: [Float] = rgbArray.map { max(Float(max($0.r, $0.g, $0.b)) / 255.0, eps) }
            let f0Frame: [Float] = rgbArray.map { lookupF0(r: Int($0.r), g: Int($0.g), b: Int($0.b)) }

            // Compute spectrum
            let totalSpectrum = self.computeTotalSpectrumGPU(amplitudeFrame: amplitudeFrame, f0Frame: f0Frame, frequencies: self.original_f)
            let fullSpectrum = mirrorAndConjugate(totalSpectrum)
            let signal = iFFT(fullSpectrum)

            // Normalize using sigmoid
            let framePeak = (signal.map { abs($0) }.max() ?? 0) + eps
            if framePeak > self.runningMax {
                self.runningMax = self.attack * framePeak + (1.0 - self.attack) * self.runningMax
            } else {
                self.runningMax = self.release * framePeak + (1.0 - self.release) * self.runningMax
            }

            var normFactor = sigmoidNormalize(x: framePeak, M: self.runningMax)
            normFactor = max(min(normFactor, 1.0), 0.0)
            let outputSignalFrame = signal.map { $0 / (framePeak / normFactor) }

            // --- Publish updates safely on main thread ---
            DispatchQueue.main.async {
                self.lastFrame = outputSignalFrame
                self.frameIndex = 0
            }
        }
    }

    
    // Mark: - Spectrum Computation
    func computeTotalSpectrumGPU(amplitudeFrame: [Float], f0Frame: [Float], frequencies: [Float]) -> [Complex] {
        let F = frequencies.count
        let P = amplitudeFrame.count

        // GPU buffers
        let amplitudeBuffer = device.makeBuffer(bytes: amplitudeFrame,
                                                length: P * MemoryLayout<Float>.stride,
                                                options: [])
        let f0Buffer = device.makeBuffer(bytes: f0Frame,
                                         length: P * MemoryLayout<Float>.stride,
                                         options: [])
        let freqBuffer = device.makeBuffer(bytes: frequencies,
                                           length: F * MemoryLayout<Float>.stride,
                                           options: [])
        
        var previous = previousSpectrum.map { simd_float2($0.real, $0.imag) }
        let previousBuffer = device.makeBuffer(bytes: &previous, length: F * MemoryLayout<simd_float2>.size, options: [])
        
        var totalSumData = [simd_float2](repeating: simd_float2(0,0), count: F)
        let totalSumBuffer = device.makeBuffer(bytes: &totalSumData, length: F * MemoryLayout<simd_float2>.size, options: [])

        var params = SpectrumParams(
            T: self.N,
            Q_scaling: self.Q_scaling,
            spectrumMixing: self.spectrumMixing,
            P: UInt32(P),
            F: UInt32(F),
            hpCutoff: self.hpCutoff,
            lpCutoff: self.lpCutoff,
            hpOrder: self.hpOrder,
            lpOrder: self.lpOrder
        )

        let paramBuffer = device.makeBuffer(bytes: &params,
                                            length: MemoryLayout<SpectrumParams>.stride,
                                            options: [])


        // Encode GPU command
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return [] }

        encoder.setComputePipelineState(computePipeline)
        encoder.setBuffer(amplitudeBuffer, offset: 0, index: 0)
        encoder.setBuffer(f0Buffer, offset: 0, index: 1)
        encoder.setBuffer(freqBuffer, offset: 0, index: 2)
        encoder.setBuffer(previousBuffer, offset: 0, index: 3)
        encoder.setBuffer(totalSumBuffer, offset: 0, index: 4)
        encoder.setBuffer(paramBuffer, offset: 0, index: 5)
        
        // Launch threads
        let threadsPerThreadgroup = MTLSize(width: 16, height: 1, depth: 1)
        let numThreadgroups = MTLSize(width: (F + 15) / 16, height: 1, depth: 1)

        encoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadsPerThreadgroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read back
        let pointer = totalSumBuffer!.contents().bindMemory(to: simd_float2.self, capacity: F)
        var result = [Complex]()
        for i in 0..<F {
            let val = pointer[i]
            result.append(Complex(val.x, val.y))
        }

        self.previousSpectrum = result
        return result
    }
    
    func computeTotalSpectrumCPU(amplitudeFrame: [Float], f0Frame: [Float], frequencies: [Float]) -> [Complex] {
        let F = frequencies.count
        let P = amplitudeFrame.count
        var totalSum = [Complex](repeating: Complex(0, 0), count: F)

        for fIdx in 0..<F {
            let fChunk = frequencies[fIdx]
            var sumChunk = Complex(0,0)

            for p in 0..<P {
                let f0 = f0Frame[p]
                let A = amplitudeFrame[p]

                // positive and negative diffs
                let diffPos = fChunk - f0
                let diffNeg = fChunk + f0

                func sinc(_ x: Float) -> Float { x == 0 ? 1 : sin(Float.pi * x) / (Float.pi * x) }

                let x0Pos = diffPos * N
                let x1Pos = (diffPos - 1.0 / N) * N
                let x2Pos = (diffPos + 1.0 / N) * N

                let x0Neg = diffNeg * N
                let x1Neg = (diffNeg - 1.0 / N) * N
                let x2Neg = (diffNeg + 1.0 / N) * N

                let WPos = (N/2) * sinc(x0Pos) - (N/4) * (sinc(x1Pos) + sinc(x2Pos))
                let WNeg = (N/2) * sinc(x0Neg) - (N/4) * (sinc(x1Neg) + sinc(x2Neg))

                var value = Complex(0, -0.5) * (Complex(WPos, 0) - Complex(WNeg, 0))

                // Weight with resonant peak
                let Q = f0 / (A * 255.0) * Q_scaling
                let denom = Complex(1, Q * (fChunk - f0))
                let resonantPeak = Complex(1,0) / denom
                value = value * resonantPeak

                // multiply by amplitude
                value = value * Complex(A,0)

                sumChunk = sumChunk + value
            }

            // Apply high-pass and low-pass filters
            if frequencies[fIdx] <= hpCutoff {
                sumChunk = sumChunk * Complex(pow(abs(frequencies[fIdx] - hpCutoff), -hpOrder), 0)
            }
            if frequencies[fIdx] >= lpCutoff {
                sumChunk = sumChunk * Complex(pow(abs(lpCutoff - frequencies[fIdx]), -lpOrder), 0)
            }

            totalSum[fIdx] = sumChunk
        }

        // Spectrum mixing with previous
        if previousSpectrum.allSatisfy({ $0.real == 0 && $0.imag == 0 }) {
            for iF in 0..<F {
                totalSum[iF] = Complex(spectrumMixing, 0) * previousSpectrum[iF] + Complex(1.0 - spectrumMixing, 0) * totalSum[iF]
            }
        }

        previousSpectrum = totalSum
        return totalSum
    }
}

