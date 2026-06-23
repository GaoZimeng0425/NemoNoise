#import "NNExceptionCatcher.h"

@implementation NNExceptionCatcher

+ (BOOL)attempt:(NS_NOESCAPE void (^)(void))block
          error:(NSError *_Nullable *_Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            info[@"NNExceptionName"] = exception.name ?: @"unknown";
            *error = [NSError errorWithDomain:@"NNObjCException" code:0 userInfo:info];
        }
        return NO;
    }
}

@end
