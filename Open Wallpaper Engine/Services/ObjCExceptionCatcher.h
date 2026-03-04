#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

/// Execute a block, catching any ObjC NSException. Returns YES on success.
+ (BOOL)performSafe:(void (NS_NOESCAPE ^)(void))block;

@end

NS_ASSUME_NONNULL_END
