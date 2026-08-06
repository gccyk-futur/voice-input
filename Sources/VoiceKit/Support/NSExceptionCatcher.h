#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 将可能抛出 NSException 的 AVFAudio 等 ObjC API 包在 @try/@catch 中，
/// 把异常转成 Swift 可捕获的 NSError。Swift 的 do/catch 无法接住 NSException，
/// 不经此桥接会直接 abort()（SIGABRT）。
@interface NSExceptionCatcher : NSObject

/// 执行 block；若抛出 NSException，返回 NO 并填充 *error（domain: NSExceptionCatcherErrorDomain）。
+ (BOOL)catchException:(void (^NS_NOESCAPE)(void))block error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
