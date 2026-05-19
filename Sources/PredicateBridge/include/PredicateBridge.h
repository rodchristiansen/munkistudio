#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Build an NSPredicate from a format string without crashing on malformed
/// input. NSPredicate raises an ObjC exception for syntax errors and those
/// don't bridge into Swift `throws`. This tiny shim catches the exception
/// and converts it to an NSError instead.
NSPredicate * _Nullable PBSafelyCreatePredicate(NSString *format,
                                                NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
