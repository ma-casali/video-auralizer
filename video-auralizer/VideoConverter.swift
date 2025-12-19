import SwiftUI
import AVFoundation
import Metal
import MetalPerformanceShaders
import Combine
import simd

struct AudioParams {
    let hpCutoff: Float
    let lpCutoff: Float
    let hpOrder: Float
    let lpOrder: Float
    let Q_scaling: Float
    let spectrumMixing: Float
    let Hanning_Window_Multiplier: Float
}

struct SpectrumParams {
    let T: Float
    let Q_scaling: Float
    let spectrumMixing: Float
    let padding0: Float = 0         // pad to align next UInt32
    
    let P: UInt32
    let F: UInt32
    let padding1: UInt32 = 0        // pad to 16 bytes
    
    let hpCutoff: Float
    let lpCutoff: Float
    let hpOrder: Float
    let lpOrder: Float
    let padding2: UInt32 = 0        // pad to 16 bytes
}


final class VideoConverter: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private var frameIndex: Int = 0
    private var audioFormat: AVAudioFormat!
    
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var textureCache: CVMetalTextureCache!
    private var computePipeline: MTLComputePipelineState!
    var metalBuffer: MTLBuffer!
    
    // audio parameters
    private let sampleRate: Float32 = 44100.0
    private let videoFs: Float32 = 30.0
    private var NFFT: Int = 4096
    private var N: Int
    private var F: Int
    @Published public var original_f: [Float] = []
    private var f: [Float] = []
    
    // future controllable parameters
    @Published public var attack: Float32 = 0.25
    @Published public var release: Float32 = 0.25
    @Published public var spectrumMixing: Float32 = 0.9
    @Published public var Q_scaling: Float32 = 1.0
    @Published public var Hanning_Window_Multiplier: Float32 = 1.0
    @Published public var hpCutoff: Float32 = 200.0
    @Published public var lpCutoff: Float32 = 18_000.0
    @Published public var hpOrder: Float32 = 1.0
    @Published public var lpOrder: Float32 = 1.0
    @Published public var downSample: Int = 8
    
    // history parameters
    private var previousSpectrumDSP: [Complex]
    @Published private(set) var previousSpectrum: [Complex]
    @Published private(set) var previousSignal: [Float]
    private var runningMax: Float = 0.0
    private var lastRGBFrame: [(r: UInt8, g: UInt8, b: UInt8)]?
    
    // buffer parameters
    private let audioBufferSize = 16
    private var audioFrames: [[Float]] = []
    private var writeIndex = 0
    private var readIndex = 0
    private var availableFrames = 0
    private let audioBufferLock = NSLock()
    
    override init() {
        print("Initalizing VideoConverter...")
        
        print("NFFT = \(self.NFFT)")
        self.N = self.NFFT - 2
        self.F = max(1, self.N/2)
        self.previousSpectrum = [Complex](repeating: Complex(0,0), count: self.F)
        self.previousSpectrumDSP = [Complex](repeating: Complex(0,0), count: self.F)
        self.previousSignal = [Float](repeating: 0, count: Int(self.N))
        
        self.audioFrames = Array(repeating: [Float](repeating: 0, count: NFFT), count: audioBufferSize)

        super.init()
        
        self.original_f = linspace(start: Float(self.F) / sampleRate, end: sampleRate / 2 + Float(self.F) / sampleRate, num: self.F)
        self.f = linearToLog2(self.original_f)
        
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

            self.audioBufferLock.lock()

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

                    let currentFrame = self.audioFrames[self.readIndex]
                    let frameSamples = currentFrame.count

                    // How many samples left to read from current frame
                    let samplesRemainingInFrame = frameSamples - self.frameIndex

                    // How many samples we can write in this callback
                    let samplesToCopy = min(samplesRemainingInFrame, Int(frameCount) - samplesWritten)

                    // Copy slice of current frame into audio buffer
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
    
    // MARK: - Setup Queues
    private let audioQueue = DispatchQueue(label: "audioQueue") // serialize audio buffer scheduling
    private let paramsQueue = DispatchQueue(label: "paramsQueue", attributes: .concurrent)
    
    private var currentAudioParams = AudioParams(
        hpCutoff: 400.0, // color spectrum frequency
        lpCutoff: 790.0, // color spectrum frequency
        hpOrder: 1.0,
        lpOrder: 1.0,
        Q_scaling: 1.0,
        spectrumMixing: 0.85,
        Hanning_Window_Multiplier: 1.0
    )
    
    func setAudioParams(_ newParams: AudioParams){
        paramsQueue.async(flags: .barrier) {
            self.currentAudioParams = newParams
        }
    }
    
    // MARK: - Process a frame of audio
    private func processFrame(texture: MTLTexture) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            let audioParams: AudioParams = self.paramsQueue.sync { self.currentAudioParams }
            
            // --- GPU -> CPU copy ---
            let width = texture.width
            let height = texture.height
            let bytesPerRow = 4 * width
            let pixelData = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 1)
            defer { pixelData.deallocate() }
            
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.getBytes(pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
            
            // Extract RGB array
            var rgbArray: [(r: UInt8, g: UInt8, b: UInt8)] = []
            let ptr = pixelData.assumingMemoryBound(to: UInt8.self)
            for y in stride(from: 0, to: height, by: self.downSample) {
                let row = ptr + y * bytesPerRow
                for x in stride(from: 0, to: width, by: self.downSample) {
                    let pixel = row + x * 4
                    rgbArray.append((r: pixel[2], g: pixel[1], b: pixel[0]))
                }
            }

            let previousRGB = lastRGBFrame
            lastRGBFrame = rgbArray
            
            // Generate amplitude and f0
            let eps: Float = 1e-9
            var amplitudeFrame: [Float] = []
            amplitudeFrame.reserveCapacity(rgbArray.count)
            
            for i in 0..<rgbArray.count {
                let curr = rgbArray[i]
                
                let r = Int(curr.r)
                let g = Int(curr.g)
                let b = Int(curr.b)
                
                var delta: Float = 0.0
                if let prev = previousRGB {
                    let p = prev[i]
                    let dr = r - Int(p.r)
                    let dg = g - Int(p.g)
                    let db = b - Int(p.b)
                    delta = Float(dr + dg + db) / (3.0 * 255.0)
                }
                let brightness = Float(max(r, max(g, b))) / 255.0
                let amplitude = pow(10.0, brightness * (0.2 + 0.8 * delta))
                
                amplitudeFrame.append(max(amplitude, eps))
            }
            
            
            let f0Frame: [Float] = rgbArray.map { lookupF0(r: Int($0.r), g: Int($0.g), b: Int($0.b)) }
            let P = amplitudeFrame.count
            
           self.paramsQueue.async(flags: .barrier) {
               self.currentAudioParams = AudioParams(
                   hpCutoff: linearToLog2Single(self.hpCutoff),
                   lpCutoff: linearToLog2Single(self.lpCutoff),
                   hpOrder: self.hpOrder,
                   lpOrder: self.lpOrder,
                   Q_scaling: self.Q_scaling,
                   spectrumMixing: self.spectrumMixing,
                   Hanning_Window_Multiplier: self.Hanning_Window_Multiplier
               )
           }
            
            let spectrumParams = SpectrumParams(
                T: Float(self.N) / audioParams.Hanning_Window_Multiplier,
                Q_scaling: audioParams.Q_scaling,
                spectrumMixing: audioParams.spectrumMixing,
                P: UInt32(P),
                F: UInt32(F),
                hpCutoff: audioParams.hpCutoff,
                lpCutoff: audioParams.lpCutoff,
                hpOrder: audioParams.hpOrder,
                lpOrder: audioParams.lpOrder
            )

            // Compute Spectrum on GPU
            self.computeTotalSpectrumGPU(
                amplitudeFrame: amplitudeFrame,
                f0Frame: f0Frame,
                frequencies: self.f,
                spectrumParams: spectrumParams
            ) { totalSpectrum in
                // Mirror and conjugate
                
                let fullSpectrum = mirrorAndConjugate(totalSpectrum)
                
                // Take the IFFT
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

                
                DispatchQueue.main.async {
                    self.previousSignal = outputSignalFrame
                }

                // Store frame in circular buffer safely
                self.audioBufferLock.lock()
                defer { self.audioBufferLock.unlock() }

                // Only overwrite if there is room (avoid overwriting unread frames)
                if self.availableFrames < self.audioBufferSize {
                    self.audioFrames[self.writeIndex] = outputSignalFrame
                    self.writeIndex = (self.writeIndex + 1) % self.audioBufferSize
                    self.availableFrames += 1
                }
            }
        }
    }
            
    // MARK: - Prepare for GPU processing
    func computeTotalSpectrumGPU(
        amplitudeFrame: [Float],
        f0Frame: [Float],
        frequencies: [Float],
        spectrumParams: SpectrumParams,
        completion: @escaping ([Complex]) -> Void
    ){
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

        var params = spectrumParams
        let paramBuffer = device.makeBuffer(bytes: &params,
                                            length: MemoryLayout<SpectrumParams>.stride,
                                            options: [])
        
        // Encode GPU command
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
                  completion([])
                  return
              }
        
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
            completion(result)
        }
        
        commandBuffer.commit()
        
    }
}

