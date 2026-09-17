#import "ZARRecallClassifier.h"
#import <Foundation/Foundation.h>

static id ZARSafeGet(id target, NSString *key) {
    if (!target || !key) return nil;
    @try { return [target valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static NSString *ZARString(id value) {
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:NSString.class]) return value;
    @try {
        if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    } @catch (__unused NSException *e) {}
    return nil;
}

BOOL ZARRecallIsMyRecall(id chatEntity) {
    id value = ZARSafeGet(chatEntity, @"_isRecallDelByMySelf");
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

BOOL ZARRecallHasRichContent(id chatEntity) {
    NSString *message = ZARString(ZARSafeGet(chatEntity, @"message"));
    if (message.length && ![message isEqualToString:@"<null>"] && ![message isEqualToString:@"<Not Found>"]) return YES;

    id rich = ZARSafeGet(chatEntity, @"richMsgNormal");
    if (rich && rich != [NSNull null] && ![rich isEqual:@"<null>"] && ![rich isEqual:@"<Not Found>"]) return YES;

    NSString *mediaId = ZARString(ZARSafeGet(chatEntity, @"mediaId"));
    if (mediaId.length && ![mediaId isEqualToString:@"<null>"] && ![mediaId isEqualToString:@"<Not Found>"]) return YES;

    id mediaType = ZARSafeGet(chatEntity, @"mediatype");
    if ([mediaType respondsToSelector:@selector(integerValue)]) return [mediaType integerValue] > 0;
    return [ZARString(mediaType) integerValue] > 0;
}
