import SwiftUI
import AVFoundation
import Metal
import MetalPerformanceShaders
import Combine
import simd
import Accelerate

protocol VisionEngineDelegate: AnyObject {
    func visionEngine(_ engine: VisionEngine, didExtractFeatures hues: [Int32], grads: [SIMD4<Float>])
}

final class VisionEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, ObservableObject {
    
    // metal parameters
    public var device: MTLDevice!
    public var commandQueue: MTLCommandQueue!
    public var textureCache: CVMetalTextureCache!
    private var computePipeline: MTLComputePipelineState!
    private var fusedPipeline: MTLComputePipelineState?
    private var histogramPipeline: MTLComputePipelineState!
    private var modesBuffer: MTLBuffer?
    private var mipTexture: MTLTexture?
    private var currentMipLevel: Int = 3
    
    // initialization of values
    @Published public var debugHue: [SIMD4<Float>]
    @Published public var debugSaturation: [SIMD4<Float>]
    @Published public var debugIntensity: [SIMD4<Float>]
    @Published public var cellAvgGrads: [SIMD4<Float>]
    @Published public var debugHSI: [Float]
    @Published public var debugSize: CGSize
    @Published public var cellMaxHues: [Int32] = Array(repeating: 0, count: 16)
    
    private let spectrumMixing: Float = 0.9
    
    weak var delegate: VisionEngineDelegate?
    
    override init() {
        self.debugHue = Array(repeating: .zero, count: 16)
        self.debugSaturation = Array(repeating: .zero, count: 16)
        self.debugIntensity = Array(repeating: .zero, count: 16)
        self.cellAvgGrads = Array(repeating: .zero, count: 16)
        self.debugHSI = Array(repeating: 0, count: 16)
        self.debugSize = .zero
        
        super.init()
    }
    
    // MARK: - Attach to camera session
    func attachToSession(_ session: AVCaptureSession) {
        session.beginConfiguration()
        for output in session.outputs {
            session.removeOutput(output)
        }
        
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoConverterQueue"))
        
        if session.canAddOutput(output) {
            session.addOutput(output)
            print("VisionEngine: Succesfully attached to session.")
        } else {
            print("VisionEngine: Could not add video output.")
        }
        
        session.commitConfiguration()
    }
    
    // MARK: - Metal Compute Setup
    func setupMetalCompute() {
        guard let library = device.makeDefaultLibrary() else {return}
        
        // gradient calculation
        guard let fusedKernel = library.makeFunction(name: "convolveFeatures") else {return}
        fusedPipeline = try? device.makeComputePipelineState(function: fusedKernel)
        
        // hue histogram calculation
        guard let histogramKernel = library.makeFunction(name: "calculateHueHistogram") else {return}
        histogramPipeline = try? device.makeComputePipelineState(function: histogramKernel)
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
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else {return}
            self.processVideoFrame(texture: self.mipTexture!)
        }
        
        commandBuffer.commit()
    }
    
    // return hues and gradients
    private func processVideoFrame(texture: MTLTexture){
        
        // downsample pixel grid according to mip level
        let width = texture.width
        let height = texture.height
        let mipWidth = width >> self.currentMipLevel
        let mipHeight = height >> self.currentMipLevel
        let mipPixelCount = mipWidth * mipHeight
        let requiredLength = mipPixelCount * MemoryLayout<Float>.stride * 4
        var mipLevel = UInt32(self.currentMipLevel)
        
        let numBins = 360
        let numCells = 16
        let histBufferSize = numCells * numBins * MemoryLayout<UInt32>.stride
        guard let histogramBuffer = self.device.makeBuffer(length: histBufferSize, options: .storageModeShared) else { return }
        memset(histogramBuffer.contents(), 0, histogramBuffer.length)
        
        // Feature/Gradient Buffers
        let float4Size = MemoryLayout<SIMD4<Float>>.stride
        guard let hueBuffer = self.device.makeBuffer(length: mipPixelCount * float4Size, options: .storageModeShared),
              let saturationBuffer = self.device.makeBuffer(length: mipPixelCount * float4Size, options: .storageModeShared),
              let intensityBuffer = self.device.makeBuffer(length: mipPixelCount * float4Size, options: .storageModeShared) else { return }
        
        guard let commandBuffer = self.commandQueue.makeCommandBuffer() else { return }
        
        // encode histogram kernel
        if let histEncoder = commandBuffer.makeComputeCommandEncoder(),
           let _ = self.histogramPipeline {
            var w = UInt32(mipWidth)
            var h = UInt32(mipHeight)
            histEncoder.setComputePipelineState(histogramPipeline)
            histEncoder.setTexture(texture, index: 0)
            histEncoder.setBuffer(histogramBuffer, offset: 0, index: 0)
            histEncoder.setBytes(&w, length: 4, index: 1)
            histEncoder.setBytes(&h, length: 4, index: 2)
            histEncoder.setBytes(&mipLevel, length: 4, index: 3)
            
            let wtg = min(device.maxThreadsPerThreadgroup.width, 16)
            let htg = min(device.maxThreadsPerThreadgroup.height, 16)
            let threadsPerGrid = MTLSize(width: mipWidth, height: mipHeight, depth: 1)
            let threadsPerThreadGroup = MTLSize(width: wtg, height: htg, depth: 1)
            histEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadGroup)
            
            histEncoder.endEncoding()
        }
        
        // encode feature/gradient kernel
        if let featEncoder = commandBuffer.makeComputeCommandEncoder(),
           let fusedPipeline = self.fusedPipeline {
            var w = UInt32(mipWidth)
            var h = UInt32(mipHeight)
            
            featEncoder.setComputePipelineState(fusedPipeline)
            featEncoder.setTexture(texture, index: 0)
            featEncoder.setBuffer(hueBuffer, offset: 0, index: 0)
            featEncoder.setBuffer(saturationBuffer, offset: 0, index: 1)
            featEncoder.setBuffer(intensityBuffer, offset: 0, index: 2)
            featEncoder.setBytes(&w, length: MemoryLayout<UInt32>.size, index: 3)
            featEncoder.setBytes(&h, length: MemoryLayout<UInt32>.size, index: 4)
            featEncoder.setBytes(&mipLevel, length: MemoryLayout<UInt32>.size, index: 5)
            
            let wtg = min(device.maxThreadsPerThreadgroup.width, 16)
            let htg = min(device.maxThreadsPerThreadgroup.height, 16)
            let threadsPerGrid = MTLSize(width: mipWidth, height: mipHeight, depth: 1)
            let threadsPerGroup = MTLSize(width: wtg, height: htg, depth: 1)
            featEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            featEncoder.endEncoding()
        }
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            
            // --- 1. Extract Hues from Histogram ---
            let histPointer = histogramBuffer.contents().assumingMemoryBound(to: UInt32.self)
            let histData = Array(UnsafeBufferPointer(start: histPointer, count: numBins * numCells))
            var updatedHues: [Int32] = self.cellMaxHues
            
            for cellIdx in 0..<16 {
                let start = cellIdx * 360
                let cellHist = histData[start..<(start + 360)]
                if let maxVal = cellHist.max(), maxVal > 20,
                   let maxIndex = cellHist.indices.max(by: { cellHist[$0] < cellHist[$1] }) {
                    let hueBin = maxIndex - start
                    updatedHues[cellIdx] = Int32(Float(updatedHues[cellIdx]) * self.spectrumMixing + Float(hueBin) * (1.0 - self.spectrumMixing))
                }
            }
            
            // --- 2. Extract and Process Gradients ---
            let intensityPtr = intensityBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            let intensityData = Array(UnsafeBufferPointer(start: intensityPtr, count: mipPixelCount))
            
            var newCellAvgGrads: [SIMD4<Float>] = Array(repeating: .zero, count: 16)
            let pixelsPerCell = mipPixelCount / 16
            
            for cellIdx in 0..<16 {
                let start = cellIdx * pixelsPerCell
                let end = (cellIdx == 15) ? mipPixelCount : (start + pixelsPerCell)
                let cellSlice = intensityData[start..<end]
                
                var sumSquaredX: Float = 0, sumAbsY: Float = 0, sumAbsZ: Float = 0, maxW: Float = 0
                for grad in cellSlice {
                    sumSquaredX += grad.x * grad.x
                    sumAbsY += abs(grad.y)
                    sumAbsZ += abs(grad.z)
                    maxW = max(maxW, abs(grad.w))
                }
                
                let countF = Float(cellSlice.count)
                newCellAvgGrads[cellIdx] = SIMD4<Float>(sqrt(sumSquaredX / countF), sumAbsY / countF, sumAbsZ / countF, maxW)
            }
            
            // --- 3. Extract Raw Data for Debuggers ---
            let hData = Array(UnsafeBufferPointer(start: hueBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: mipPixelCount))
            let sData = Array(UnsafeBufferPointer(start: saturationBuffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: mipPixelCount))
            
            // --- 4. Notify SoundEngine via Delegate ---
            self.delegate?.visionEngine(self, didExtractFeatures: updatedHues, grads: newCellAvgGrads)
            
            // --- 5. Update UI on Main Thread ---
            DispatchQueue.main.async {
                self.cellMaxHues = updatedHues
                self.cellAvgGrads = newCellAvgGrads
                self.debugHue = hData
                self.debugSaturation = sData
                self.debugIntensity = intensityData
                self.debugSize = CGSize(width: mipWidth, height: mipHeight)
            }
        }
        
        commandBuffer.commit()
    }
}
