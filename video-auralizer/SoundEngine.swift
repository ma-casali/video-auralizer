import SwiftUI
import AVFoundation
import Metal
import MetalPerformanceShaders
import Combine
import simd
import Accelerate

struct AudioParameters {
    let hpCutoff: Float
    let lpCutoff: Float
    let hpOrder: Float
    let lpOrder: Float
    let spectrumMixing: Float
}

struct SpectrumParameters {

    var F: Int32
    var spectrumMixing: Float
    var binWidth: Float
    var hpCutoff: Float
    
    var lpCutoff: Float
    var hpOrder: Float
    var lpOrder: Float
    var _padding: Float = 0.0
    
}

public class SoundEngine: NSObject, ObservableObject {
    
    // metal parameters
    public var device: MTLDevice!
    public var commandQueue: MTLCommandQueue!
    private var textureCache: CVMetalTextureCache!
    private var computePipeline: MTLComputePipelineState!
    private var modesBuffer: MTLBuffer?
    private var mipTexture: MTLTexture?
    
    // MARK: - Setup Queues
    private let audioQueue = DispatchQueue(label: "audioQueue")
    private let paramsQueue = DispatchQueue(label: "paramsQueue", attributes: .concurrent)
    
    // audio parameters
    private let sampleRate: Float32 = 44100.0
    private let videoFs: Float32 = 30.0
    private var NFFT: Int = 4096
    private var T: Float = 0.0
    private var N: Int
    private var F: Int
    @Published public var original_f: [Float] = []
    private var f: [Float] = []
    private var binWidth: Float = 0.0
    private var phaseOffset: Float = 0.0
    private var currentAudioParameters = AudioParameters(
        hpCutoff: 20.0,
        lpCutoff: 20_000.0,
        hpOrder: 0.0,
        lpOrder: 0.0,
        spectrumMixing: 0.85,
    )
    private var previousSpectrumDSP: [Complex]
    @Published private(set) var previousSpectrum: [Complex]
    @Published public var previousSignal: [Float]
    @Published public var attack: Float32 = 1.0
    @Published public var release: Float32 = 1.0
    @Published public var spectrumMixing: Float32 = 0.9
    @Published public var hpCutoff: Float32 = 200.0
    @Published public var lpCutoff: Float32 = 18_000.0
    @Published public var hpOrder: Float32 = 0.0
    @Published public var lpOrder: Float32 = 0.0
    private var runningMax: Float = 1.0
    
    @Published public var currentMipLevel: Int = 3
    
    // audio format parameters
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private var audioFormat: AVAudioFormat!
    private var frameIndex: Int = 0
    
    // latency parameters
    @Published public var processingLatency: Double = 0.0
    
    // buffer parameters
    var metalBuffer: MTLBuffer!
    private let audioBufferSize = 16
    private var audioFrames: [[Float]] = []
    private var writeIndex = 0
    private var readIndex = 0
    private var availableFrames = 0
    private let audioBufferLock = NSLock()
    private var currentFrameSeed: Float = 0.0
    private var olaBuffer = [Float](repeating: 0, count: 4096) // tail of the previous frame
    private let hopSize: Int = 2048
    private let window: [Float] = {
        var w = [Float](repeating: 0, count: 4096)
        vDSP_hann_window(&w, 4096, Int32(vDSP_HANN_NORM))
        return w
    }()
    private var phaseAccumulation = [Float](repeating: 0.0, count: 16 * (13 + 9)) // one for each cell-harmonic combo 
    private var isBufferWarmedUp: Bool = false
    
    private let besselRatios: [Float] = [
        // j11 = 3.8317
        1.0964, // j31
        1.7292, // j12
        1.7502, // j22
        1.8309, // j02
        2.0918, // j32
        2.2278, // j13
        2.6018, // j23
        2.6651, // j03
        2.9611, // j33
    ]
    
    // MARK: - Initialization
    override init() {
        self.N = self.NFFT - 2
        self.F = max(2, self.N / 2)
        self.previousSpectrum = [Complex](repeating: Complex(0,0), count: self.F)
        self.previousSpectrumDSP = [Complex](repeating: Complex(0,0), count: self.F)
        self.previousSignal = [Float](repeating: 0, count: Int(self.N))
        
        self.audioFrames = Array(repeating: [Float](repeating: 0, count: self.hopSize), count: audioBufferSize)
        
        super.init()
        
        self.original_f = linspace(start: sampleRate / Float(self.F), end: sampleRate / 2 + sampleRate / Float(self.F), num: self.F)
        self.f = linearToLog2(self.original_f)
        self.binWidth = (self.sampleRate / Float(self.N) )
    }
    
    // MARK: - Metal Setup
    func setupMetalCompute() {
        guard let library = device.makeDefaultLibrary() else {return}
        
        // spectrum computation
        guard let kernel = library.makeFunction(name: "computeSpectrum") else { return }
        computePipeline = try? device.makeComputePipelineState(function: kernel)
    }
    
    // MARK: - Audio Setup
    func setupAudio() {
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

            self.audioBufferLock.lock()
                if self.availableFrames < 3 && !self.isBufferWarmedUp {
                    self.audioBufferLock.unlock()
                    return noErr
                }
                self.isBufferWarmedUp = true
            
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            
            for buffer in ablPointer {
                let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
                var samplesWritten: Int = 0
                
                while samplesWritten < Int(frameCount) {
                    if self.availableFrames == 0 {
                        // No data ready: fill remaining requested samples with zeros
                        buf[ samplesWritten ] = 0.0
                        samplesWritten += 1
                        continue
                    }
                    
                    // send samples to buffer
                    let currentFrame = self.audioFrames[self.readIndex]
                    let frameSamples = currentFrame.count
                    let samplesRemainingInFrame = frameSamples - self.frameIndex
                    let samplesToCopy = min(samplesRemainingInFrame, Int(frameCount) - samplesWritten)
                    
                    let slice = currentFrame[self.frameIndex ..< self.frameIndex + samplesToCopy]
                    slice.withUnsafeBufferPointer { ptr in
                        buf.advanced(by: samplesWritten).update(from: ptr.baseAddress!, count: samplesToCopy)
                    }
                    
                    // Update counters
                    samplesWritten += samplesToCopy
                    self.frameIndex += samplesToCopy
                    
                    if self.frameIndex >= frameSamples {
                        // Finished reading current frame → move to next frame
                        self.frameIndex = 0
                        self.readIndex = (self.readIndex + 1) % self.audioBufferSize
                        self.availableFrames -= 1
                    }
                }
            }
            
            self.audioBufferLock.unlock()
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
    
    // MARK: - OLA
    func applyOverlapAdd(signal: [Float]) -> [Float] {
        
        let framePeak = signal.map { abs($0) }.max() ?? 1.0
        let gain = 1.0 / (framePeak + 1e-6)
        var normalized = [Float](repeating: 0, count: 4096)
        vDSP_vsmul(signal, 1, [gain], &normalized, 1, 4096)
        
        var windowed = [Float](repeating: 0, count: 4096)
        vDSP_vmul(normalized, 1, self.window, 1, &windowed, 1, 4096)
        
        var output = [Float](repeating: 0, count: 2048)
        
        self.olaBuffer.withUnsafeBufferPointer { prevPtr in
            windowed.withUnsafeBufferPointer { currPtr in
                vDSP_vadd(prevPtr.baseAddress! + 2048, 1,
                          currPtr.baseAddress!, 1,
                          &output, 1, 2048)
            }
        }
        
        self.olaBuffer = windowed
        
        return output
    }
    
    // MARK: - Phase Accumulation
    func applyPhaseAccumulation(hues: [Int32]) -> [Float] {
        for cell in 0..<16 {
            
            let hueValue = Double(hues[cell])
            let f0_raw = Float(220.0 * pow(2.0, (hueValue / 360.0) * 3.0))
            
            let f0Index = findClosestIndex(freqs: self.original_f, target: f0_raw)
            let f0 = self.original_f[f0Index] // This is the Float frequency
            
            // Classical Harmonics loop
            for h in 1...13 {
                let hFreq = f0 * Float(h)
                let idx = (cell * (13 + 9)) + (h - 1)
                
                // Explicitly cast all components to Float
                let phaseAdvance = (Float.pi * 2.0 * hFreq * Float(self.hopSize)) / Float(self.sampleRate)
                self.phaseAccumulation[idx] = (self.phaseAccumulation[idx] + phaseAdvance).truncatingRemainder(dividingBy: Float.pi * 2.0)
            }
            
            // Bessel loop
            for b in 0..<9 {
                let bFreq = f0 * Float(self.besselRatios[b])
                let idx = (cell * (13 + 9)) + 13 + b // Offset by 13 to not overwrite harmonics
                
                let phaseAdvance = (Float.pi * 2.0 * bFreq * Float(self.hopSize)) / Float(self.sampleRate)
                self.phaseAccumulation[idx] = (self.phaseAccumulation[idx] + phaseAdvance).truncatingRemainder(dividingBy: Float.pi * 2.0)
            }
        }
        return self.phaseAccumulation
    }
    
    // MARK: - GPU Spectrum Computation
    func computeTotalSpectrumGPU(
        fundamentals: [Int32],
        grads: [SIMD4<Float>],
        frequencies: [Float],
        P: Int,
        startTime: Double,
        spectrumParameters: SpectrumParameters,
        completion: @escaping ([Complex], Double) -> Void
    ){
        let F = frequencies.count
        var previous = previousSpectrum.map { simd_float2($0.real, $0.imag) }
        var totalSumData = [simd_float2](repeating: simd_float2(0,0), count: F)
        var params = spectrumParameters
        
        // GPU buffers
        let fundamentalsBuffer = device.makeBuffer(bytes: fundamentals, length: 16 * MemoryLayout<Int32>.stride, options: [])
        let gradsBuffer = device.makeBuffer(bytes: grads, length: 16 * MemoryLayout<SIMD4<Float>>.stride, options: [])
        let freqBuffer = device.makeBuffer(bytes: frequencies, length: F * MemoryLayout<Float>.stride, options: [])
        let previousBuffer = device.makeBuffer(bytes: &previous, length: F * MemoryLayout<simd_float2>.size, options: [])
        let phaseAccumulationBuffer = device.makeBuffer(bytes: &self.phaseAccumulation, length: (16 * (13 + 9)) * MemoryLayout<Float>.size, options: [])
        let totalSumBuffer = device.makeBuffer(bytes: &totalSumData, length: F * MemoryLayout<simd_float2>.size, options: [])
        let paramBuffer = device.makeBuffer(bytes: &params, length: MemoryLayout<SpectrumParameters>.stride, options: [])
        
        // Encode GPU command
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            completion([], 0)
            return
        }
        
        encoder.setComputePipelineState(computePipeline)
        encoder.setBuffer(fundamentalsBuffer, offset: 0, index: 0)
        encoder.setBuffer(gradsBuffer, offset: 0, index: 1)
        encoder.setBuffer(freqBuffer, offset: 0, index: 2)
        encoder.setBuffer(previousBuffer, offset: 0, index: 3)
        encoder.setBuffer(phaseAccumulationBuffer, offset: 0, index: 4)
        encoder.setBuffer(totalSumBuffer, offset: 0, index: 5)
        encoder.setBuffer(paramBuffer, offset: 0, index: 6)
        
        // Launch threads
        let threadsPerThreadgroup = MTLSize(width: 16, height: 1, depth: 1)
        let numThreadgroups = MTLSize(width: (F + 15) / 16, height: 1, depth: 1)
        
        encoder.dispatchThreadgroups(numThreadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        
        // Completion Handler
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else {return}
            
            // readback immediately
            let ptr = totalSumBuffer!
                .contents()
                .bindMemory(to: simd_float2.self, capacity: F)
            var result = [Complex]()
            result.reserveCapacity(F)
            for i in 0..<F {
                result.append(Complex(ptr[i].x, ptr[i].y))
            }
            
            // update dsp state on audio queue
            self.audioQueue.async {
                self.previousSpectrumDSP = result
            }
            
            // update published spectrum on main queue
            DispatchQueue.main.async {
                self.previousSpectrum = result
            }
            
            // call completion closure
            completion(result, startTime)
        }
        
        commandBuffer.commit()
        
    }
    
    // MARK: - Audio Frame Rendering
    func renderAudioFrame(hues: [Int32], grads: [SIMD4<Float>], P: Int, startTime: Double) -> [Float] {
        // Update Phase Accumulation
        self.phaseAccumulation = self.applyPhaseAccumulation(hues: hues)

        // Update Audio Parameters
        self.paramsQueue.async(flags: .barrier) {
            self.currentAudioParameters = AudioParameters(
                hpCutoff: self.hpCutoff,
                lpCutoff: self.lpCutoff,
                hpOrder: self.hpOrder,
                lpOrder: self.lpOrder,
                spectrumMixing: self.spectrumMixing,
            )
        }
        
        // Populate new audio parameters
        let spectrumParams = SpectrumParameters(
            F: Int32(self.F),
            spectrumMixing: self.currentAudioParameters.spectrumMixing,
            binWidth: self.binWidth,
            hpCutoff: self.currentAudioParameters.hpCutoff,
            lpCutoff: self.currentAudioParameters.lpCutoff,
            hpOrder: self.currentAudioParameters.hpOrder,
            lpOrder: self.currentAudioParameters.lpOrder
        )
        
        // MARK: - Spectrum Computation
        
        self.computeTotalSpectrumGPU(
            fundamentals: hues,
            grads: grads,
            frequencies: self.original_f,
            P: P,
            startTime: startTime,
            spectrumParameters: spectrumParams
        ){(summedSpectrum, startTime) in
            
            // Mirror and conjugate
            let fullSpectrum = mirrorAndConjugate(summedSpectrum)
            
            // Take the IFFT
            let signal = iFFT(fullSpectrum)
            
            // Normalize using sigmoid
            let eps = 1e-9
            let framePeak = Float32((signal.map { Double(abs($0)) }.max() ?? 0) + eps)
            if framePeak > self.runningMax {
                self.runningMax = self.attack * framePeak + (1.0 - self.attack) * self.runningMax
            } else {
                self.runningMax = self.release * framePeak + (1.0 - self.release) * self.runningMax
            }
            var normFactor = sigmoidNormalize(x: framePeak, M: self.runningMax)
            normFactor = max(min(normFactor, 1.0), 0.0)
            let normValue = framePeak / normFactor
            
            var normalizedSignal = [Float](repeating: 0, count: signal.count)
            if normValue != 0 {
                vDSP.divide(signal, normValue, result: &normalizedSignal)
            }
            
            let outputSignalFrame = self.applyOverlapAdd(signal: normalizedSignal)
            
            // calculate latency
            let endTime = CACurrentMediaTime()
            let totalLatency = (endTime - startTime) * 1000
            let hardwareOutputLatency = self.hardwareLatency
            let trueLatency = totalLatency + hardwareOutputLatency
            
            DispatchQueue.main.async {
                self.previousSignal = outputSignalFrame
                self.processingLatency = trueLatency
            }
            
            // Store frame in circular buffer safely
            self.audioBufferLock.lock()
            defer { self.audioBufferLock.unlock() }
            
            print(self.availableFrames)
            
            // Only overwrite if there is room (avoid overwriting unread frames)
            if self.availableFrames < self.audioBufferSize {
                self.audioFrames[self.writeIndex] = outputSignalFrame
                self.writeIndex = (self.writeIndex + 1) % self.audioBufferSize
                self.availableFrames += 1
                
            }
        }
        return self.previousSignal
    }
    
    // MARK: - Stop Method
    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        
        audioBufferLock.lock()
        availableFrames = 0
        readIndex = 0
        writeIndex = 0
        frameIndex = 0
        
        olaBuffer = [Float](repeating: 0, count: 4096)
        audioBufferLock.unlock()
        
        print("SoundEngine: Audio stopped and buffers cleared.")
    }
}

extension SoundEngine {
    var hardwareLatency: Double {
        let session = AVAudioSession.sharedInstance()
        let outputLatency = session.outputLatency
        let ioBufferDuration = session.ioBufferDuration
        let engineLatency = audioEngine.outputNode.presentationLatency
        return (outputLatency + ioBufferDuration + engineLatency) * 1000
    }
}
