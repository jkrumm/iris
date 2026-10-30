#import "IrisObjCGuard.h"

@implementation IrisObjCGuard

+ (BOOL)perform:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error {
  @try {
    block();
    return YES;
  } @catch (NSException *exception) {
    if (error) {
      NSString *description = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"no reason"];
      *error = [NSError errorWithDomain:@"IrisObjCGuard" code:1 userInfo:@{NSLocalizedDescriptionKey : description}];
    }
    return NO;
  }
}

@end
