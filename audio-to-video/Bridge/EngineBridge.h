// EngineBridge.h

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import EngineBridge.h

@interface EngineBridge : NSObject

// Initialize the C++ engine with the Metal Device from Swift
- (instancetype)initWithDevice:(id<MTLDevice>)device;

// Start the audio capture and beamforming
- (void)startProcessing;

// Stop the engine
- (void)stopProcessing;

// Get the synthesized texture to display in the MTKView
- (id<MTLTexture>)getLatestFrame;

@end
