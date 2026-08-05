#import "NSExceptionCatcher.h"

NSString *const NSExceptionCatcherErrorDomain = @"NSExceptionCatcherErrorDomain";

@implementation NSExceptionCatcher

+ (BOOL)catchException:(void (^NS_NOESCAPE)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            userInfo[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
            if (exception.name) userInfo[@"name"] = exception.name;
            if (exception.userInfo) userInfo[@"userInfo"] = exception.userInfo;
            *error = [NSError errorWithDomain:NSExceptionCatcherErrorDomain
                                         code:1
                                     userInfo:userInfo];
        }
        return NO;
    }
}

@end
