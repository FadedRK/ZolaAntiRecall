#import "ZARRecallInterceptor.h"
#import "ZARRecallCache.h"
#import "ZARRecallClassifier.h"
#import "../Core/ZARLogger.h"
#import "../Settings/ZARSettings.h"
#import <objc/runtime.h>

static void (*ZAROriginalUpdateUndoMessageContent)(id, SEL, id) = NULL;
static BOOL ZARRecallHookInstalled = NO;

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

static NSString *ZARTag(BOOL mine, BOOL rich) {
    NSString *language = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
    if ([language hasPrefix:@"zh"]) return mine ? @"【你已撤回】" : (rich ? @"【内容已被对方撤回】" : @"【已被对方撤回】");
    if ([language hasPrefix:@"vi"]) return mine ? @"【Bạn đã thu hồi】" : (rich ? @"【Nội dung đã bị đối phương thu hồi】" : @"【Đã bị đối phương thu hồi】");
    return mine ? @"【You recalled this message】" : (rich ? @"【Content recalled by the other person】" : @"【Recalled by the other person】");
}

static NSString *ZARTagged(NSString *original, NSString *tag) {
    if (!original.length || !tag.length) return nil;
    if ([original hasSuffix:tag]) return original;
    return [NSString stringWithFormat:@"%@\n%@", original, tag];
}

static BOOL ZARSetMessage(id chatEntity, NSString *message) {
    if (!chatEntity || !message.length) return NO;
    @try {
        [chatEntity setValue:message forKey:@"message"];
        NSString *after = ZARString(ZARSafeGet(chatEntity, @"message"));
        BOOL ok = [after isEqualToString:message];
        ZARLog(@"[ZAR-RECALL] set message %@", ok ? @"SUCCESS" : @"FAILED");
        return ok;
    } @catch (NSException *e) {
        ZARLog(@"[ZAR-RECALL] set message EXCEPTION: %@", e);
        return NO;
    }
}

static void ZARIntercept(id self, SEL cmd, id chatEntity) {
    if (!chatEntity) {
        if (ZAROriginalUpdateUndoMessageContent) ZAROriginalUpdateUndoMessageContent(self, cmd, chatEntity);
        return;
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"ZolaAntiRecallEnabled"] && ![defaults boolForKey:@"ZolaAntiRecallEnabled"]) {
        ZARLog(@"[ZAR-RECALL] master switch OFF -> ORIGINAL");
        if (ZAROriginalUpdateUndoMessageContent) ZAROriginalUpdateUndoMessageContent(self, cmd, chatEntity);
        return;
    }

    BOOL mine = ZARRecallIsMyRecall(chatEntity);
    if (mine && !ZARSettings.sharedInstance.showMyRecallEnabled) {
        ZARLog(@"[ZAR-RECALL] self-recall display disabled -> ORIGINAL");
        if (ZAROriginalUpdateUndoMessageContent) ZAROriginalUpdateUndoMessageContent(self, cmd, chatEntity);
        return;
    }

    id messageId = ZARSafeGet(chatEntity, @"messageId");
    NSString *original = ZARString(ZARSafeGet(chatEntity, @"message"));
    if (!original.length) original = ZARString(ZARSafeGet(chatEntity, @"originTextRecallMsg"));
    if (!original.length) original = ZARRecallCachedMessage(messageId);

    BOOL rich = ZARRecallHasRichContent(chatEntity);
    NSString *tag = ZARTag(mine, rich);
    NSString *replacement = ZARTagged(original, tag);
    if (!replacement.length && rich) replacement = tag;

    if (!replacement.length) {
        ZARLog(@"[ZAR-RECALL] original content unavailable -> ORIGINAL");
        if (ZAROriginalUpdateUndoMessageContent) ZAROriginalUpdateUndoMessageContent(self, cmd, chatEntity);
        return;
    }

    ZARLog(@"[ZAR-RECALL] INTERCEPT mine=%@ rich=%@ messageId=%@", mine ? @"YES" : @"NO", rich ? @"YES" : @"NO", messageId);
    if (ZARSetMessage(chatEntity, replacement)) {
        ZARLog(@"[ZAR-RECALL] original updateUndoMessageContent: BLOCKED");
    } else if (ZAROriginalUpdateUndoMessageContent) {
        ZARLog(@"[ZAR-RECALL] replacement failed -> ORIGINAL");
        ZAROriginalUpdateUndoMessageContent(self, cmd, chatEntity);
    }
}

static void ZARHook(id self, SEL cmd, id chatEntity) {
    @autoreleasepool { ZARIntercept(self, cmd, chatEntity); }
}

void ZARInstallRecallInterceptor(void) {
    if (ZARRecallHookInstalled) return;
    Class cls = objc_getClass("UndoChatProcessor");
    if (!cls) { ZARLog(@"[ZAR-RECALL] UndoChatProcessor NOT FOUND"); return; }

    SEL selector = NSSelectorFromString(@"updateUndoMessageContent:");
    Method method = class_getInstanceMethod(cls, selector);
    BOOL classMethod = NO;
    if (!method) {
        method = class_getClassMethod(cls, selector);
        classMethod = method != NULL;
    }
    if (!method) { ZARLog(@"[ZAR-RECALL] updateUndoMessageContent: NOT FOUND"); return; }

    const char *types = method_getTypeEncoding(method);
    IMP original = method_getImplementation(method);
    ZARLog(@"[ZAR-RECALL] target=%@ method=%@ types=%s IMP=%p", NSStringFromClass(cls), classMethod ? @"CLASS" : @"INSTANCE", types ?: "(null)", original);
    if (!original || !types || strcmp(types, "v24@0:8@16") != 0) {
        ZARLog(@"[ZAR-RECALL] signature mismatch -> abort");
        return;
    }
    if (original == (IMP)ZARHook) { ZARRecallHookInstalled = YES; return; }

    ZAROriginalUpdateUndoMessageContent = (void (*)(id, SEL, id))original;
    method_setImplementation(method, (IMP)ZARHook);
    ZARRecallHookInstalled = YES;
    ZARLog(@"[ZAR-RECALL] FINAL HOOK INSTALLED on UndoChatProcessor.%@", NSStringFromSelector(selector));
}
