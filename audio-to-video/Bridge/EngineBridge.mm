// Engine Bridge
// Connects swift to UI Engine

#import "EngineBridge.h"
#include "AcousticEngine.hpp" // Your actual C++ Engine

@implementation EngineBridge {
    // This is a C++ pointer hidden inside the Objective-C class
    std::unique_ptr<AcousticEngine> _cppEngine;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (self) {
        // Pass the Metal device down to C++
        // (Note: metal-cpp allows casting id<MTLDevice> to MTL::Device*)
        _cppEngine = std::make_unique<AcousticEngine>((__bridge void*)device);
    }
    return self;
}

- (void)startProcessing {
    _cppEngine->start();
}

- (void)stopProcessing {
    _cppEngine->stop();
}

- (id<MTLTexture>)getLatestFrame {
    return (__bridge id<MTLTexture>)_cppEngine->getOutputTexture();
}

@end
