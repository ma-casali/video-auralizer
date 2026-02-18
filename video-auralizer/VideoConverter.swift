import SwiftUI
import AVFoundation
import Metal
import MetalPerformanceShaders
import Combine
import simd
import Accelerate

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
    let frameSeed: Float
    
    let P: UInt32
    let F: UInt32
    let binWidth: Float
    let padding0: UInt32 = 0
    
    let hpCutoff: Float
    let lpCutoff: Float
    let hpOrder: Float
    let lpOrder: Float
}

struct ModeMultipliers {
    var breathing: Float
    var verticalTilt: Float
    var horizontalTilt: Float
    var shear: Float
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
    private var histogramPipeline: MTLComputePipelineState!
    private var modesBuffer: MTLBuffer?
    private var mipTexture: MTLTexture?
    
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
    private var currentAudioParams = AudioParams(
        hpCutoff: 4000.0, // color spectrum frequency
        lpCutoff: 790.0, // color spectrum frequency
        hpOrder: 0.0,
        lpOrder: 0.0,
        Q_scaling: 1.0,
        spectrumMixing: 0.85,
        Hanning_Window_Multiplier: 1.0
    )
    
    private let besselRatios: [Float] = [
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
    ]

    
    // controllable parameters
    @Published public var attack: Float32 = 0.25
    @Published public var release: Float32 = 0.25
    @Published public var spectrumMixing: Float32 = 0.9
    @Published public var Q_scaling: Float32 = 1.0
    @Published public var Hanning_Window_Multiplier: Float32 = 1.0
    @Published public var hpCutoff: Float32 = 200.0
    @Published public var lpCutoff: Float32 = 18_000.0
    @Published public var hpOrder: Float32 = 0.0
    @Published public var lpOrder: Float32 = 0.0
    @Published public var currentMipLevel: Int = 3
    
    // mode emphasis control
    @Published public var breathingMode: Float = 1.0
    @Published public var verticalTiltMode: Float = 1.0
    @Published public var horizontalTiltMode: Float = 1.0
    @Published public var shearMode: Float = 1.0
    
    // history parameters
    private var previousSpectrumDSP: [Complex]
    @Published private(set) var previousSpectrum: [Complex]
    private var phaseAccumulation = [Float](repeating: 0.0, count: 16 * (13 + 9))
    @Published private(set) var previousSignal: [Float]
    private var runningMax: Float = 1.0
    private var lastRGBFrame: [(r: UInt8, g: UInt8, b: UInt8)]?
    
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
    private var persistentPhases = [Float](repeating: 0.0, count: 4096)
    
    @Published public var debugHue: [SIMD4<Float>]
    @Published public var debugSaturation: [SIMD4<Float>]
    @Published public var debugIntensity: [SIMD4<Float>]
    @Published public var cellAvgGrads: [SIMD4<Float>]
    @Published public var debugHSI: [Float]
    @Published public var debugSize: CGSize
    
    @Published public var cellMaxHues: [Int] = Array(repeating: 0, count: 16)
    
    // MARK: - Initialization
    override init() {
        print("Initalizing VideoConverter...")
        print("NFFT = \(self.NFFT)")
        
        self.N = self.NFFT - 2
        self.F = max(1, self.N/2)
        self.previousSpectrum = [Complex](repeating: Complex(0,0), count: self.F)
        self.previousSpectrumDSP = [Complex](repeating: Complex(0,0), count: self.F)
        self.previousSignal = [Float](repeating: 0, count: Int(self.N))
        self.audioFrames = Array(repeating: [Float](repeating: 0, count: self.hopSize), count: audioBufferSize)
        
        self.debugHue = []
        self.debugSaturation = []
        self.debugIntensity = []
        self.cellAvgGrads = []
        self.debugHSI = []
        self.debugSize = .zero

        super.init()
        
        self.original_f = linspace(start: sampleRate / Float(self.F), end: sampleRate / 2 + sampleRate / Float(self.F), num: self.F)
        self.f = linearToLog2(self.original_f)
        self.binWidth = (self.sampleRate / Float(self.N) )
        
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
        
        // graident calculation
        guard let fusedKernel = library.makeFunction(name: "convolveFeatures") else {return}
        fusedPipeline = try? device.makeComputePipelineState(function: fusedKernel)
        
        // hue histogram calculation
        guard let histogramKernel = library.makeFunction(name: "calculateHueHistogram") else {return}
        histogramPipeline = try? device.makeComputePipelineState(function: histogramKernel)
        
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
            destinationLevel: 0,
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
    
    // MARK: - Public processing of frame
    func processManualBuffer(_ pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        var cvTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
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
              let sourceTexture = CVMetalTextureGetTexture(cvTexture) else { return }
        
        // allow support for mipmaps
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: true
        )
        desc.usage = [.shaderRead, .shaderWrite]
        
        guard let mipmappedTexture = device.makeTexture(descriptor: desc),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }

        // 2. Copy the manual buffer into the mipmapped texture
        blitEncoder.copy(from: sourceTexture, to: mipmappedTexture)
        
        // 3. Generate the mipmaps so that mipLevel 3 actually exists
        blitEncoder.generateMipmaps(for: mipmappedTexture)
        blitEncoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.processFrame(texture: mipmappedTexture)
        }
        
        commandBuffer.commit()
}
    
    // MARK: - Find top n peaks in histogram
    private func findTopNPeaks(histogram: [UInt32], n: Int, minDistance: Int) -> [Int] {
        let numBins = histogram.count
        var selectedPeaks: [Int] = []
        
        // 1. Create a list of all indices sorted by their histogram value (descending)
        let sortedIndices = histogram.indices.sorted { histogram[$0] > histogram[$1] }
        
        for index in sortedIndices {
            // Stop if we've found enough peaks
            if selectedPeaks.count >= n { break }
            
            // Ignore noise (optional threshold)
            if histogram[index] < 10 { break }
            
            // 2. Check if this index is far enough from already selected peaks
            let isFarEnough = selectedPeaks.allSatisfy { existingPeak in
                let diff = abs(index - existingPeak)
                let circularDist = min(diff, numBins - diff)
                return circularDist >= minDistance
            }
            
            if isFarEnough {
                selectedPeaks.append(index)
            }
        }
        
        return selectedPeaks
    }
    
    private func applyOverlapAdd(signal: [Float]) -> [Float] {
        // 1. Normalize current block
        let framePeak = signal.map { abs($0) }.max() ?? 1.0
        let gain = 1.0 / (framePeak + 1e-6)
        var normalized = [Float](repeating: 0, count: 4096)
        vDSP_vsmul(signal, 1, [gain], &normalized, 1, 4096)

        // 2. Apply Hann Window to the time-domain signal
        var windowed = [Float](repeating: 0, count: 4096)
        vDSP_vmul(normalized, 1, self.window, 1, &windowed, 1, 4096)

        // 3. Sum the FIRST half of current with the SECOND half of previous
        var output = [Float](repeating: 0, count: 2048)
        
        // Previous Tail (stored in olaBuffer)
        self.olaBuffer.withUnsafeBufferPointer { prevPtr in
            windowed.withUnsafeBufferPointer { currPtr in
                // Add second half of old buffer to first half of new buffer
                vDSP_vadd(prevPtr.baseAddress! + 2048, 1,
                          currPtr.baseAddress!, 1,
                          &output, 1, 2048)
            }
        }

        // 4. Update the Tail for the next frame
        self.olaBuffer = windowed
        
        return output
    }
    
    /// Finds the index of the value in 'freqs' closest to 'target'
    private func findClosestIndex(freqs: [Float], target: Float) -> Int {
        let count = freqs.count
        if count == 0 { return 0 }
        
        var low = 0
        var high = count - 1
        
        // Binary search
        while low <= high {
            let mid = low + (high - low) / 2
            if freqs[mid] < target {
                low = mid + 1
            } else if freqs[mid] > target {
                high = mid - 1
            } else {
                return mid // Exact match found
            }
        }
        
        // Boundary checks
        if low >= count { return count - 1 }
        if low <= 0 { return 0 }
        
        // Determine which of the two remaining neighbors is actually closer
        let diffCurrent = abs(freqs[low] - target)
        let diffPrevious = abs(freqs[low - 1] - target)
        
        return diffCurrent < diffPrevious ? low : low - 1
    }
    

    // MARK: - Process a frame of audio
    private func processFrame(texture: MTLTexture) {
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            
            // increment frame seed
            self.currentFrameSeed += 1.0
            if self.currentFrameSeed > 10_000.0 { self.currentFrameSeed = 0.0 }
            
            // Grab audio parameters
            let audioParams: AudioParams = self.paramsQueue.sync { self.currentAudioParams }
            
            // downsample pixel grid according to mip level
            let width = texture.width
            let height = texture.height
            let mipWidth = width >> self.currentMipLevel
            let mipHeight = height >> self.currentMipLevel
            let mipPixelCount = mipWidth * mipHeight
            let requiredLength = mipPixelCount * MemoryLayout<Float>.stride * 4
            var mipLevel = UInt32(self.currentMipLevel)
            
            // MARK: - Metal Computation of Spectrogram
            let numBins = 360
            let numCells = 16
            let bufferSize = numCells * numBins * MemoryLayout<UInt32>.stride
            let outputBuffer = self.device.makeBuffer(length: bufferSize, options: .storageModeShared)
            
            if let buffer = outputBuffer {
                memset(buffer.contents(), 0, buffer.length)
            }
            
            guard let outputBuffer = outputBuffer,
                  let commandBuffer = self.commandQueue.makeCommandBuffer(),
                  let histEncoder = commandBuffer.makeComputeCommandEncoder(),
                  let histogramPipeline = self.histogramPipeline else {
                print("Failed to create histogram buffer, encoder, or pipeline")
                return
            }
            
            var w = UInt32(mipWidth)
            var h = UInt32(mipHeight)
            histEncoder.setComputePipelineState(histogramPipeline)
            histEncoder.setTexture(texture, index: 0)
            histEncoder.setBuffer(outputBuffer, offset: 0, index: 0)
            histEncoder.setBytes(&w, length: 4, index: 1)
            histEncoder.setBytes(&h, length: 4, index: 2)
            histEncoder.setBytes(&mipLevel, length: 4, index: 3)
            
            let wtg = min(device.maxThreadsPerThreadgroup.width, 16)
            let htg = min(device.maxThreadsPerThreadgroup.height, 16)
            let threadsPerGrid = MTLSize(width: mipWidth, height: mipHeight, depth: 1)
            let threadsPerThreadGroup = MTLSize(width: wtg, height: htg, depth: 1)
            histEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadGroup)
            
            histEncoder.endEncoding()
            commandBuffer.addCompletedHandler { _ in
                let rawPointer = outputBuffer.contents().assumingMemoryBound(to: UInt32.self)
                let allData = Array(UnsafeBufferPointer(start: rawPointer, count: numBins * numCells))
                
                var updatedHues = self.cellMaxHues
                let mixing = self.spectrumMixing

                for cellIdx in 0..<16 {
                    let start = cellIdx * 360
                    let end = start + 360
                    let cellHist = allData[start..<end]
                    
                    if let maxVal = cellHist.max(), maxVal > 20 {
                        if let maxIndex = cellHist.indices.max(by: { cellHist[$0] < cellHist[$1] }) {
                            let hueBin = Float(maxIndex - 360 * cellIdx)
                            let currentStoredHue = Float(updatedHues[cellIdx])
                            let originalMix = currentStoredHue * mixing
                            let newMix = hueBin * (1.0 - mixing)
                            updatedHues[cellIdx] = Int(originalMix + newMix)
                        }
                    }
                }

                DispatchQueue.main.async {
                    self.cellMaxHues = updatedHues
                }
                
            }
            
            commandBuffer.commit()
            
            // MARK: - Metal Computation of Gradients
            // set up output buffer for GPU compute
            let hueBuffer = self.device.makeBuffer(length: requiredLength, options: .storageModeShared)
            let saturationBuffer = self.device.makeBuffer(length: requiredLength, options: .storageModeShared)
            let intensityBuffer = self.device.makeBuffer(length: requiredLength, options: .storageModeShared)
            let hsiBuffer = self.device.makeBuffer(length: mipPixelCount * MemoryLayout<SIMD3<Int>>.stride, options: .storageModeShared)
            
            guard let hueBuffer = hueBuffer, let saturationBuffer = saturationBuffer, let intensityBuffer = intensityBuffer, let hsiBuffer = hsiBuffer,
                  let commandBuffer = self.commandQueue.makeCommandBuffer(),
                  let featureEncoder = commandBuffer.makeComputeCommandEncoder(),
                  let fusedPipeline = self.fusedPipeline else {
                print("Failed to create command buffer, encoder, or pipeline")
                return
            }
          
            // encode bytes for GPU compute
            featureEncoder.setComputePipelineState(fusedPipeline)
            featureEncoder.setTexture(texture, index: 0)
            featureEncoder.setBuffer(hueBuffer, offset: 0, index: 0)
            featureEncoder.setBuffer(saturationBuffer, offset: 0, index: 1)
            featureEncoder.setBuffer(intensityBuffer, offset: 0, index: 2)
            
            assert(self.currentMipLevel < texture.mipmapLevelCount)
            featureEncoder.setBytes(&w, length: 4, index: 3)
            featureEncoder.setBytes(&h, length: 4, index: 4)
            featureEncoder.setBytes(&mipLevel, length: 4, index: 5)
            
            featureEncoder.setBuffer(hsiBuffer, offset: 0, index: 6)

            featureEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadGroup)
            
            featureEncoder.endEncoding()
            
            commandBuffer.addCompletedHandler { _ in
                
                let hueData = Array(UnsafeBufferPointer(start: hueBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: mipPixelCount))
                let saturationData = Array(UnsafeBufferPointer(start: saturationBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: mipPixelCount))
                let intensityData = Array(UnsafeBufferPointer(start: intensityBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: mipPixelCount))
//                let hsiData = Array(UnsafeBufferPointer(start: hsiBuffer.contents().assumingMemoryBound(to: SIMD3<Float>.self), count: mipPixelCount))
                
                // Calculate cell averages for each type of intensity gradient
                
                var cellAvgGrads: [SIMD4<Float>] = Array(repeating: .zero, count: 16)

                for cellIdx in 0..<16 {
                    let pixelsPerCell = intensityData.count / 16
                    let start = cellIdx * pixelsPerCell
                    let end = (cellIdx == 15) ? intensityData.count : (start + pixelsPerCell)
                    let cellGrads = intensityData[start..<end]
                    
                    var sumSquaredX: Float = 0
                    var sumAbsY: Float = 0
                    var sumAbsZ: Float = 0
                    var maxW: Float = 0
                    
                    for grad in cellGrads {
                        // RMS for Breathing (Power)
                        sumSquaredX += grad.x * grad.x
                        
                        // Absolute for Tilts (Dominance)
                        sumAbsY += abs(grad.y)
                        sumAbsZ += abs(grad.z)
                        
                        // Peak for Saddle (Detection of sharp features)
                        maxW = max(maxW, abs(grad.w))
                    }
                    
                    let countF = Float(cellGrads.count)
                    
                    // Combine them back into a SIMD4 for the Debugger and Synth
                    cellAvgGrads[cellIdx] = SIMD4<Float>(
                        sqrt(sumSquaredX / countF), // RMS
                        sumAbsY / countF,           // Mean Absolute
                        sumAbsZ / countF,           // Mean Absolute
                        maxW                        // Peak
                    )
                }
                
                DispatchQueue.main.async {
                    self.debugHue = hueData
                    self.debugSaturation = saturationData
                    self.debugIntensity = intensityData
                    self.debugSize = CGSize(width: mipWidth, height: mipHeight)
                    self.cellAvgGrads = cellAvgGrads
                }
                
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
                
                self.T += Float(self.hopSize) / 44100.0
                
                let spectrumParams = SpectrumParams(
                     T: self.T,
                     Q_scaling: audioParams.Q_scaling,
                     spectrumMixing: audioParams.spectrumMixing,
                     frameSeed: self.currentFrameSeed,
                     P: UInt32(mipPixelCount),
                     F: UInt32(self.F),
                     binWidth: self.binWidth,
                     hpCutoff: audioParams.hpCutoff,
                     lpCutoff: audioParams.lpCutoff,
                     hpOrder: audioParams.hpOrder,
                     lpOrder: audioParams.lpOrder
                 )
                
                 // MARK: - Spectrum Computation
                 self.computeTotalSpectrumGPU(
                     fundamentals: self.cellMaxHues,
                     grads: self.cellAvgGrads,
                     frequencies: self.original_f,
                     P: Int(mipPixelCount),
                     spectrumParams: spectrumParams
                 ) { totalSpectrum in
                     
                     // take care of phase accumulation first
                     for cell in 0..<16 {
                         // 1. Ensure the power math is done in Double, then cast to Float
                         let hueValue = Double(self.cellMaxHues[cell])
                         let f0_raw = Float(220.0 * pow(2.0, (hueValue / 360.0) * 3.0))
                         
                         // 2. findClosestIndex returns an Int (index).
                         // We need to look up the actual frequency value at that index.
                         let f0Index = self.findClosestIndex(freqs: self.original_f, target: f0_raw)
                         let f0 = self.original_f[f0Index] // This is the Float frequency
                         
                         // Harmonics loop
                         for h in 1...13 { // Using 1...13 to include the 13th harmonic
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
                     let normValue = framePeak / normFactor
                     
                     var normalizedSignal = [Float](repeating: 0, count: signal.count)
                     if normValue != 0 {
                         vDSP.divide(signal, normValue, result: &normalizedSignal)
                     }
                     
                     let outputSignalFrame = self.applyOverlapAdd(signal: normalizedSignal)
                     
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
        fundamentals: [Int?],
        grads: [SIMD4<Float>],
        frequencies: [Float],
        P: Int,
        spectrumParams: SpectrumParams,
        completion: @escaping ([Complex]) -> Void
    ){
        let F = frequencies.count
        
        // GPU buffers
        let fundamentalsBuffer = device.makeBuffer(bytes: fundamentals,
                                                   length: 16 * MemoryLayout<SIMD4<Float>>.stride,
                                                   options: [])
        let gradsBuffer = device.makeBuffer(bytes: grads,
                                            length: 16 * MemoryLayout<SIMD4<Float>>.stride,
                                            options: [])

        let freqBuffer = device.makeBuffer(bytes: frequencies,
                                           length: F * MemoryLayout<Float>.stride,
                                           options: [])
        
        var previous = previousSpectrum.map { simd_float2($0.real, $0.imag) }
        
        let previousBuffer = device.makeBuffer(bytes: &previous, length: F * MemoryLayout<simd_float2>.size, options: [])
        
        let phaseAccumulationBuffer = device.makeBuffer(bytes: &self.phaseAccumulation, length: F * MemoryLayout<Float>.size, options: [])
        
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
            completion(result)
        }
        
        commandBuffer.commit()
        
    }
}

