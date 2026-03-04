import SwiftUI
import AVFoundation
import Metal
import MetalPerformanceShaders
import Combine
import simd
import Accelerate

final class VideoToAudio: ObservableObject {
    public var visionEngine = VisionEngine()
    public var soundEngine = SoundEngine()
    
    private let captureSession = AVCaptureSession()
    
    @Published var isRunning = false

    private var cancellables = Set<AnyCancellable>()
    
    init() {
        
        let sharedDevice = MTLCreateSystemDefaultDevice()!
        let commandQueue = sharedDevice.makeCommandQueue()
        var textureCache: CVMetalTextureCache!
        CVMetalTextureCacheCreate(nil, nil, sharedDevice, nil, &textureCache)
        
        visionEngine.device = sharedDevice
        visionEngine.textureCache = textureCache
        visionEngine.commandQueue = commandQueue
        soundEngine.device = sharedDevice
        soundEngine.commandQueue = commandQueue
        
        setupEngines()
        setupCamera()
        
        // connect notifications from each engine to VideoToAudio
        visionEngine.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        soundEngine.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
    }
    
    private func setupEngines() {
        visionEngine.setupMetalCompute()
        
        soundEngine.setupAudio()
        soundEngine.setupMetalCompute()
        
        visionEngine.delegate = self
        
        print("Engines Setup: Delegate Assigned.")
    }
    
    private func setupCamera() {
        visionEngine.attachToSession(captureSession)
        
        guard let videoDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) else {
            print("Camera Error: Could not find back camera.")
            captureSession.commitConfiguration()
            return
        }
        
        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            if captureSession.canAddInput(videoDeviceInput) {
                captureSession.addInput(videoDeviceInput)
                print("Camera Setup: Input added successfully.")
            } else {
                print("Camera Error: Could not add input to session.")
            }
        } catch {
            print("Camera Error: \(error.localizedDescription)")
        }
        
        captureSession.commitConfiguration()
    }
    
    func toggleProcessing() {
        let shouldStart = !isRunning
    
        if shouldStart {
            DispatchQueue.main.async {
                self.soundEngine.setupAudio()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if shouldStart {
                self.captureSession.startRunning()
            } else {
                self.captureSession.stopRunning()
                // Stop sound on main as well
                DispatchQueue.main.async {
                    self.soundEngine.stop()
                }
            }
            
            DispatchQueue.main.async {
                self.isRunning = shouldStart
            }
        }
    }
}

extension VideoToAudio: VisionEngineDelegate {
    func visionEngine(_ engine: VisionEngine, didExtractFeatures hues: [Int32], grads: [SIMD4<Float>]) {
        _ = soundEngine.renderAudioFrame(hues: hues, grads: grads, P: 0)
    }
}
