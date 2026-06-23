#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Bridges Objective-C `NSException` into a recoverable error for Swift.
///
/// Swift's `do/catch` cannot catch an Objective-C `NSException` — it unwinds
/// straight to `objc_exception_throw` → `std::terminate` → `abort()`. Some
/// AppKit/AVFoundation calls (notably `-[AVAudioNode installTapOnBus:...]`)
/// still raise `NSException` for invalid arguments, which happens transiently
/// while a Bluetooth device switches the A2DP↔HFP profile. Wrapping such a call
/// in `@try/@catch` here lets Swift handle it instead of crashing.
@interface NNExceptionCatcher : NSObject

/// Runs `block`. Returns YES if it completed; if it raised an `NSException`,
/// catches it and returns NO with `error` populated (domain `NNObjCException`,
/// the exception name in `userInfo[@"NNExceptionName"]`, its reason as the
/// localized description). Imported into Swift as a throwing method.
+ (BOOL)attempt:(NS_NOESCAPE void (^)(void))block
          error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
