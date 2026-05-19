#import "PredicateBridge.h"

NSPredicate * _Nullable PBSafelyCreatePredicate(NSString *format,
                                                NSError * _Nullable * _Nullable error) {
    @try {
        return [NSPredicate predicateWithFormat:format];
    } @catch (NSException *exception) {
        if (error) {
            NSDictionary *info = @{
                NSLocalizedDescriptionKey: exception.reason ?: @"Invalid predicate format"
            };
            *error = [NSError errorWithDomain:@"PredicateBridge" code:1 userInfo:info];
        }
        return nil;
    }
}
