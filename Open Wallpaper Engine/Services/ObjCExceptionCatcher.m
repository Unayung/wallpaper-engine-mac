#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)performSafe:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[ObjCExceptionCatcher] Caught: %@", exception.reason);
        return NO;
    }
}

@end
