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

struct Modes {
    var I_c: SIMD2<Float>
    var S_c: SIMD2<Float>
    var I: SIMD4<Float>
    var S: SIMD4<Float>
    var f0: SIMD4<Float>
}

final class VideoConverter: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    // MARK: - Define class parameters
    
    // MARK: - Setup Queues
    private let audioQueue = DispatchQueue(label: "audioQueue") // serialize audio buffer scheduling
    private let paramsQueue = DispatchQueue(label: "paramsQueue", attributes: .concurrent)
    
    // audio format parameters
    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private var audioFormat: AVAudioFormat!
    private var frameIndex: Int = 0
    
    // metal parameters
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var textureCache: CVMetalTextureCache!
    private var computePipeline: MTLComputePipelineState!
    private var fusedPipeline: MTLComputePipelineState?
    private var modesBuffer: MTLBuffer?
    private var mipTexture: MTLTexture?
    
    // audio parameters
    private let sampleRate: Float32 = 44100.0
    private let videoFs: Float32 = 30.0
    private var NFFT: Int = 4096
    private var N: Int
    private var F: Int
    @Published public var original_f: [Float] = []
    private var f: [Float] = []
    private var currentAudioParams = AudioParams(
        hpCutoff: 400.0, // color spectrum frequency
        lpCutoff: 790.0, // color spectrum frequency
        hpOrder: 1.0,
        lpOrder: 1.0,
        Q_scaling: 1.0,
        spectrumMixing: 0.85,
        Hanning_Window_Multiplier: 1.0
    )
    
    // controllable parameters
    @Published public var attack: Float32 = 0.25
    @Published public var release: Float32 = 0.25
    @Published public var spectrumMixing: Float32 = 0.9
    @Published public var Q_scaling: Float32 = 1.0
    @Published public var Hanning_Window_Multiplier: Float32 = 1.0
    @Published public var hpCutoff: Float32 = 200.0
    @Published public var lpCutoff: Float32 = 18_000.0
    @Published public var hpOrder: Float32 = 1.0
    @Published public var lpOrder: Float32 = 1.0
    @Published public var currentMipLevel: Int = 3
    
    // controllable parameters not implemented yet
    @Published public var peakAlpha:            Float32 = 1.0
    @Published public var saddleAlpha:          Float32 = 1.0
    @Published public var vertGradientAlpha:    Float32 = 1.0
    @Published public var horzGradientAlpha:    Float32 = 1.0
    
    // history parameters
    private var previousSpectrumDSP: [Complex]
    @Published private(set) var previousSpectrum: [Complex]
    @Published private(set) var previousSignal: [Float]
    private var runningMax: Float = 0.0
    private var lastRGBFrame: [(r: UInt8, g: UInt8, b: UInt8)]?
    
    // buffer parameters
    var metalBuffer: MTLBuffer!
    private let audioBufferSize = 16
    private var audioFrames: [[Float]] = []
    private var writeIndex = 0
    private var readIndex = 0
    private var availableFrames = 0
    private let audioBufferLock = NSLock()
    
    // MARK: - Initialization
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
        
        // rgb to hsi values computation
        guard let fusedKernel = library.makeFunction(name: "computeOrthogonalModesFromTexture") else {return}
        fusedPipeline = try? device.makeComputePipelineState(function: fusedKernel)
        
        // spectrum computation
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
    
    // MARK: - Capture Output
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            let device = self.device,
            let commandQueue = self.commandQueue
        else {
            print("Pixel buffer, device, or commandQueue not initialized properly.")
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Create Metal texture from camera pixel buffer
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

        guard
            status == kCVReturnSuccess,
            let cvTexture = cvTextureOut,
            let cameraTexture = CVMetalTextureGetTexture(cvTexture)
        else { return }

        // Create or resize mipmapped texture if needed
        let needsNewTexture =
            mipTexture == nil ||
            mipTexture!.width != width ||
            mipTexture!.height != height

        if needsNewTexture {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: true
            )

            desc.usage = [.shaderRead]
            desc.storageMode = .private

            mipTexture = device.makeTexture(descriptor: desc)
        }

        guard let mipTexture = mipTexture else { return }

        // GPU copy + mipmap generation
        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { return }

        // Copy camera frame
        blit.copy(
            from: cameraTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: width, height: height, depth: 1),
            to: mipTexture,
            destinationSlice: 0,
            destinationLevel: self.currentMipLevel,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )

        // Generate mipmap chain
        blit.generateMipmaps(for: mipTexture)
        blit.endEncoding()

        // --------------------------------------------------
        // Schedule processing AFTER mipmaps are ready
        // --------------------------------------------------
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            self.processFrame(texture: mipTexture)
        }

        commandBuffer.commit()
    }
    
    func setAudioParams(_ newParams: AudioParams){
        paramsQueue.async(flags: .barrier) {
            self.currentAudioParams = newParams
        }
    }

    // MARK: - Process a frame of audio
    private func processFrame(texture: MTLTexture) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Grab audio parameters
            let audioParams: AudioParams = self.paramsQueue.sync { self.currentAudioParams }
            
            // downsample pixel grid according to mip level
            let width = texture.width
            let height = texture.height
            let mipWidth = width >> self.currentMipLevel
            let mipHeight = height >> self.currentMipLevel
            let mipPixelCount = mipWidth * mipHeight
            let requiredLength = mipPixelCount * MemoryLayout<Modes>.stride

            // set up output buffer for GPU compute
            if modesBuffer == nil || modesBuffer!.length < requiredLength {
                modesBuffer = device.makeBuffer(length: requiredLength, options: .storageModeShared)
            }
            guard let modesBuffer = modesBuffer else { return }
            guard let commandBuffer = self.commandQueue.makeCommandBuffer(),
                  let computeEncoder = commandBuffer.makeComputeCommandEncoder(),
                  let fusedPipeline = self.fusedPipeline else {
                print("Failed to create command buffer, encoder, or pipeline")
                return
            }
          
            // encode bytes for GPU compute
            computeEncoder.setComputePipelineState(fusedPipeline)
            computeEncoder.setTexture(texture, index: 0)
            computeEncoder.setBuffer(modesBuffer, offset: 0, index: 0)
            
            var w = UInt32(mipWidth)
            var h = UInt32(mipHeight)
            assert(self.currentMipLevel < texture.mipmapLevelCount)
            var mipLevel = UInt32(self.currentMipLevel)
            computeEncoder.setBytes(&w, length: 4, index: 1)
            computeEncoder.setBytes(&h, length: 4, index: 2)
            computeEncoder.setBytes(&mipLevel, length: 4, index: 3)
            
            let wtg = min(device.maxThreadsPerThreadgroup.width, 16)
            let htg = min(device.maxThreadsPerThreadgroup.height, 16)
            let threadsPerThreadGroup = MTLSize(width: wtg, height: htg, depth: 1)
            let threadsPerGrid = MTLSize(width: mipWidth, height: mipHeight, depth: 1)
            computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadGroup)
            
            computeEncoder.endEncoding()
            
            commandBuffer.addCompletedHandler { _ in
                let modesPointer = modesBuffer.contents().bindMemory(to: Modes.self, capacity: mipPixelCount)
                let modesArray: [Modes] = Array(UnsafeBufferPointer(start: modesPointer, count: mipPixelCount))
                
                // implement orthogonal alterations to amplitude and Q
                let amplitudeFrame = modesArray.map { Float(1.0/(1.0 + exp(-10 * ($0.I_c.x + $0.I.x + $0.I.y + $0.I.z + $0.I.w)))) }
                let Qsigmoid = modesArray.map{ Float(4.0/(1.0 + exp(-2 * ($0.S_c.x + $0.S.x + $0.S.y + $0.S.z + $0.S.w)))) - 2.0 }
                let QFrame = Qsigmoid.map { Float(pow(10.0, $0)) }
                let f0Frame = modesArray.map{ Float($0.f0.x) }
                
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
                     P: UInt32(mipPixelCount),
                     F: UInt32(self.F),
                     hpCutoff: audioParams.hpCutoff,
                     lpCutoff: audioParams.lpCutoff,
                     hpOrder: audioParams.hpOrder,
                     lpOrder: audioParams.lpOrder
                 )

                 // Compute Spectrum on GPU
                 self.computeTotalSpectrumGPU(
                     amplitudeFrame: amplitudeFrame,
                     QFrame: QFrame,
                     f0Frame: f0Frame,
                     frequencies: self.f,
                     spectrumParams: spectrumParams
                 ) { totalSpectrum in
                     // Mirror and conjugate
                     let fullSpectrum = mirrorAndConjugate(totalSpectrum)
                     
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
            
            commandBuffer.commit()
        }
    }
            
    // MARK: - Prepare for GPU processing
    func computeTotalSpectrumGPU(
        amplitudeFrame: [Float],
        QFrame: [Float],
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
        let QBuffer = device.makeBuffer(bytes: QFrame,
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
        encoder.setBuffer(QBuffer, offset: 0, index: 1)
        encoder.setBuffer(f0Buffer, offset: 0, index: 2)
        encoder.setBuffer(freqBuffer, offset: 0, index: 3)
        encoder.setBuffer(previousBuffer, offset: 0, index: 4)
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
            completion(result)
        }
        
        commandBuffer.commit()
        
    }
}

