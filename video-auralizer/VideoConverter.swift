import SwiftUI
import AVFoundation
import Metal
import MetalPerformanceShaders
import Combine

final class VideoConverter: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private let session = AVCaptureSession()
    private let audioEngine = AVAudioEngine()
    
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var textureCache: CVMetalTextureCache!
    
    // audio parameters
    private let sampleRate: Float32 = 44100.0
    private let videoFs: Float32 = 30.0
    
    override init() {
        
        let N: Float32 = floor(sampleRate / videoFs)
        let F: Float32 = floor(N / 2)
        let original_f = linspace(start: F / sampleRate, end: sampleRate / 2 + F / sampleRate, num: Int(F))
        let f = linearToLog2(original_f)
        
        super.init()
        loadFrequencyLUT()
        setupMetal()
        setupAudio()
        setupCamera()
    }
    
    // MARK: - Metal Setup
    private func setupMetal() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device.makeCommandQueue()
        
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }
    
    // MARK: - Audio Setup
    private func setupAudio() {
        let source = AVAudioSourceNode { (_, _, frameCount, audioBufferList) -> OSStatus in
            // TODO: fill audioBufferList with synthesized audio
            return noErr
        }
        audioEngine.attach(source)
        
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        audioEngine.connect(source, to: audioEngine.mainMixerNode, format: format)
        
        try? audioEngine.start()
    }
    
    // MARK: - Camera Setup
    private func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480  // safe resolution to avoid -12710
        
        guard let camera = AVCaptureDevice.default(for: .video) else { return }
        let input = try! AVCaptureDeviceInput(device: camera)
        session.addInput(input)
        
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        let outputQueue = DispatchQueue(label: "cameraQueue", qos: .userInitiated)
        output.setSampleBufferDelegate(self, queue: outputQueue)
        session.addOutput(output)
        
        session.commitConfiguration()
        session.startRunning()
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
    private func processFrame(texture: MTLTexture) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        // --- GPU -> CPU copy (safe for small resolutions) ---
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        let pixelData = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 1)
        defer { pixelData.deallocate() }
        
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.getBytes(pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        
        // Make RGB array
        var rgbArray: [(r: UInt8, g: UInt8, b: UInt8)] = []

        let ptr = pixelData.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = ptr + y * bytesPerRow
            for x in 0..<width {
                let pixel = row + x * 4 // BGRA
                let b = pixel[0]
                let g = pixel[1]
                let r = pixel[2]
                rgbArray.append((r: r, g: g, b: b))
            }
        }
        
        
        let amplitudeFrame: [Float] = rgbArray.map { pixel in
            let maxChannel = max(pixel.r, pixel.g, pixel.b)
            return Float(maxChannel) / 255.0
        }
        
        let f0Frame: [Float] = rgbArray.map { pixel in
            return lookupF0(r: Int(pixel.r), g: Int(pixel.g), b: Int(pixel.b))
            }
        
        computeTotalSpectrum(amplitudeFrame: amplitudeFrame, f0Frame: f0Frame, frequencies: <#T##[Float]#>, T: <#T##Float#>)
        
        commandBuffer.commit()
    }
    
    func computeTotalSpectrum(amplitudeFrame: [Float], f0Frame: [Float], frequencies: [Float], T: Float, chunkSize: Int = 64) -> [Complex] {
        let F = frequencies.count
        let P = f0Frame.count
        
        var totalSum = [Complex](repeating: Complex(0,0), count: F)
        
        for start in stride(from: 0, to: F, by: chunkSize) {
            let end = min(start + chunkSize, F)
            
            for fIdx in start..<end {
                let fChunk = frequencies[fIdx]
                
                var hannChunk = [Complex](repeating: Complex(0,0), count: P)
                
                for p in 0..<P {
                    let f0 = f0Frame[p]
                    let A = amplitudeFrame[p]
                    
                    //positive and negative diffs
                    let diffPos = fChunk - f0
                    let diffNeg = fChunk + f0
                    
                    //Hann Transform
                    let x0Pos = diffPos * T
                    let x1Pos = (diffPos - 1.0 / T) * T
                    let x2Pos = (diffPos + 1.0 / T) * T
                    
                    let x0Neg = diffNeg * T
                    let x1Neg = (diffNeg - 1.0 / T) * T
                    let x2Neg = (diffNeg + 1.0 / T) * T
                    
                    
                    func sinc(_ x: Float) -> Float {
                        x == 0 ? 1 : sin(Float.pi * x) / (Float.pi * x)
                        
                    }
                    
                    let WPos = (T/2) * sinc(x0Pos) - (T/4) * (sinc(x1Pos) + sinc(x2Pos))
                    let WNeg = (T/2) * sinc(x0Neg) - (T/4) * (sinc(x1Neg) + sinc(x2Neg))
                    
                    var value = Complex(0, -0.5) * (Complex(WPos, 0) - Complex(WNeg, 0))
                    
                    // Weight with resonant peak
                    let Q = f0 / (A * 255.0) // optionally scale
                    let denom = Complex(1, Q * (fChunk - f0))
                    let resonantPeak = Complex(1, 0) / denom
                    value = value * resonantPeak
                    
                    // multiply by amplitude
                    value = value * Complex(A, 0)
                    
                    hannChunk[p] = value
                }
                // sum over P
                var sumChunk = Complex(0, 0)
                for p in 0..<P {
                    sumChunk = sumChunk + hannChunk[p]
                }
                totalSum[fIdx] = sumChunk
            }
        }
        
        return totalSum
        
    }

}

