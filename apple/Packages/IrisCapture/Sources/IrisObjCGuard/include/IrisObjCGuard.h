#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AVAudioEngine reports some failures as Objective-C exceptions (`installTapOnBus:` with a format that disagrees with the
/// hardware, for one), which Swift cannot catch and which abort the process. This runs a block and turns such an exception
/// into an error.
@interface IrisObjCGuard : NSObject

/// Runs `block`. `NO` with `error` set (domain `IrisObjCGuard`, the exception's name and reason in the description) when it
/// raised.
+ (BOOL)perform:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
