#import "ZARMessageTrace.h"
#import "../Core/ZARLogger.h"
#import "../Settings/ZARSettings.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/lock.h>

static void (*ZAROriginalUpdateUndoMessageContent)(id, SEL, id) = NULL;
static BOOL ZARUndoProbeInstalled = NO;

static NSMutableDictionary *ZARRecallOriginalMessageCache;
static os_unfair_lock ZARRecallCacheLock = OS_UNFAIR_LOCK_INIT;

static void ZAREnsureRecallCache(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZARRecallOriginalMessageCache = [NSMutableDictionary dictionary];
    });
}

static id ZARSafeGetValue(id target, NSString *key)
{
    if (!target || !key) return nil;
    @try {
        return [target valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *ZARSafeStringValue(id value)
{
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) return value;
    @try {
        NSString *stringValue = [value stringValue];
        if ([stringValue isKindOfClass:[NSString class]]) return stringValue;
    } @catch (__unused NSException *exception) {
    }
    return nil;
}

static NSString *ZARSafeDescription(id obj)
{
    if (!obj) return @"(nil)";
    @try {
        NSString *desc = [obj description];
        if (![desc isKindOfClass:[NSString class]]) return @"<non-string description>";
        return desc.length > 1000 ? [desc substringToIndex:1000] : desc;
    } @catch (__unused NSException *exception) {
        return @"<description exception>";
    }
}

static id ZARSafeMessageId(id obj)
{
    return ZARSafeGetValue(obj, @"messageId");
}

static NSString *ZARCacheKeyForMessageId(id messageId)
{
    if (!messageId) return nil;
    NSString *stringValue = ZARSafeStringValue(messageId);
    if (stringValue.length) return [NSString stringWithFormat:@"s:%@", stringValue];
    return [NSString stringWithFormat:@"o:%@", ZARSafeDescription(messageId)];
}

static void ZARCacheOriginalMessage(id messageId, NSString *message)
{
    if (!messageId || !message.length) return;
    ZAREnsureRecallCache();
    NSString *key = ZARCacheKeyForMessageId(messageId);
    if (!key) return;
    os_unfair_lock_lock(&ZARRecallCacheLock);
    ZARRecallOriginalMessageCache[key] = [message copy];
    os_unfair_lock_unlock(&ZARRecallCacheLock);
    ZARLog(@"[ZAR-RECALL] cached original message: key=%@ text=%@", key, message);
}

static NSString *ZARCachedOriginalMessage(id messageId)
{
    if (!messageId) return nil;
    ZAREnsureRecallCache();
    NSString *key = ZARCacheKeyForMessageId(messageId);
    if (!key) return nil;
    os_unfair_lock_lock(&ZARRecallCacheLock);
    NSString *message = [ZARRecallOriginalMessageCache[key] copy];
    os_unfair_lock_unlock(&ZARRecallCacheLock);
    return message;
}

static NSString *ZARLocalizedRecallTag(BOOL isMyRecall)
{
    NSArray<NSString *> *languages = [NSLocale preferredLanguages];
    NSString *language = languages.firstObject.lowercaseString ?: @"";

    if ([language hasPrefix:@"zh"]) {
        return isMyRecall ? @"【你已撤回】" : @"【已被对方撤回】";
    }
    if ([language hasPrefix:@"vi"]) {
        return isMyRecall ? @"【Bạn đã thu hồi】" : @"【Đã bị đối phương thu hồi】";
    }
    return isMyRecall ? @"【You recalled this message】" : @"【Recalled by the other person】";
}

static NSString *ZARTaggedMessage(NSString *original, NSString *tag)
{
    if (!original.length || !tag.length) return nil;
    if ([original hasSuffix:tag]) return original;
    return [NSString stringWithFormat:@"%@\n%@", original, tag];
}

static BOOL ZARIsRecallDelByMySelf(id chatEntity)
{
    id value = ZARSafeGetValue(chatEntity, @"_isRecallDelByMySelf");
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

static NSString *ZARRecallTextForOther(id chatEntity)
{
    id messageId = ZARSafeMessageId(chatEntity);
    NSString *currentMessage = ZARSafeStringValue(ZARSafeGetValue(chatEntity, @"message"));
    if (currentMessage.length) {
        ZARCacheOriginalMessage(messageId, currentMessage);
        return currentMessage;
    }
    return ZARCachedOriginalMessage(messageId);
}

static NSString *ZARRecallTextForMyself(id chatEntity)
{
    NSString *origin = ZARSafeStringValue(ZARSafeGetValue(chatEntity, @"originTextRecallMsg"));
    if (origin.length) {
        ZARCacheOriginalMessage(ZARSafeMessageId(chatEntity), origin);
        return origin;
    }
    return ZARCachedOriginalMessage(ZARSafeMessageId(chatEntity));
}

static BOOL ZARSetMessageSafely(id chatEntity, NSString *message)
{
    if (!chatEntity || !message.length) return NO;
    @try {
        [chatEntity setValue:message forKey:@"message"];
        NSString *after = ZARSafeStringValue(ZARSafeGetValue(chatEntity, @"message"));
        BOOL success = [after isEqualToString:message];
        ZARLog(@"[ZAR-RECALL] set message %@", success ? @"SUCCESS" : @"FAILED");
        return success;
    } @catch (NSException *exception) {
        ZARLog(@"[ZAR-RECALL] set message EXCEPTION: %@", exception);
        return NO;
    }
}

static void ZARRefreshEntityInMemory(id chatEntity)
{
    ZARLog(@"[ZAR-RECALL] ChatEntity memory updated; no private UI refresh invoked");
}

static void ZARHandleRecallWithoutOriginal(id self, SEL _cmd, id chatEntity)
{
    if (!chatEntity) {
        if (ZAROriginalUpdateUndoMessageContent) {
            ZAROriginalUpdateUndoMessageContent(self, _cmd, chatEntity);
        }
        return;
    }

    BOOL isMyRecall = ZARIsRecallDelByMySelf(chatEntity);

    // True native pass-through: do not inspect or mutate the entity before orig.
    if (isMyRecall && ![ZARSettings sharedInstance].showMyRecallEnabled) {
        ZARLog(@"[ZAR-RECALL] my recall display disabled -> ORIGINAL PASS-THROUGH");
        if (ZAROriginalUpdateUndoMessageContent) {
            ZAROriginalUpdateUndoMessageContent(self, _cmd, chatEntity);
        }
        return;
    }

    NSString *originalMessage = isMyRecall
        ? ZARRecallTextForMyself(chatEntity)
        : ZARRecallTextForOther(chatEntity);

    NSString *tag = ZARLocalizedRecallTag(isMyRecall);
    NSString *taggedMessage = ZARTaggedMessage(originalMessage, tag);

    if (!taggedMessage.length) {
        ZARLog(@"[ZAR-RECALL] original text unavailable -> ORIGINAL");
        if (ZAROriginalUpdateUndoMessageContent) {
            ZAROriginalUpdateUndoMessageContent(self, _cmd, chatEntity);
        }
        return;
    }

    ZARLog(@"[ZAR-RECALL] ===== INTERCEPT updateUndoMessageContent: =====");
    ZARLog(@"[ZAR-RECALL] isMyRecall=%@ showMyRecall=%@", isMyRecall ? @"YES" : @"NO", [ZARSettings sharedInstance].showMyRecallEnabled ? @"YES" : @"NO");
    ZARLog(@"[ZAR-RECALL] tag=%@", tag);
    ZARLog(@"[ZAR-RECALL] BLOCK ORIGINAL; preserve entity message");

    BOOL messageUpdated = ZARSetMessageSafely(chatEntity, taggedMessage);
    if (messageUpdated) {
        ZARRefreshEntityInMemory(chatEntity);
    }

    ZARLog(@"[ZAR-RECALL] ===== INTERCEPT EXIT =====");
}

static void ZARHookUpdateUndoMessageContent(id self, SEL _cmd, id chatEntity)
{
    @autoreleasepool {
        ZARHandleRecallWithoutOriginal(self, _cmd, chatEntity);
    }
}

static void ZARInstallDiffProbe(void)
{
    if (ZARUndoProbeInstalled) {
        ZARLog(@"[ZAR-RECALL] hook already installed");
        return;
    }

    Class targetClass = objc_getClass("UndoChatProcessor");
    if (!targetClass) {
        ZARLog(@"[ZAR-RECALL] UndoChatProcessor NOT FOUND after delay");
        return;
    }

    ZARLog(@"[ZAR-RECALL] UndoChatProcessor FOUND: %p", targetClass);

    SEL selector = NSSelectorFromString(@"updateUndoMessageContent:");
    Method targetMethod = class_getInstanceMethod(targetClass, selector);
    BOOL isClassMethod = NO;
    if (!targetMethod) {
        targetMethod = class_getClassMethod(targetClass, selector);
        if (targetMethod) {
            isClassMethod = YES;
            ZARLog(@"[ZAR-RECALL] FOUND as CLASS METHOD!");
        }
    } else {
        ZARLog(@"[ZAR-RECALL] FOUND as INSTANCE METHOD!");
    }

    if (!targetMethod) {
        ZARLog(@"[ZAR-RECALL] updateUndoMessageContent: STRICTLY NOT FOUND");
        return;
    }

    const char *types = method_getTypeEncoding(targetMethod);
    IMP original = method_getImplementation(targetMethod);
    ZARLog(@"[ZAR-RECALL] selector=%@ methodKind=%@ types=%s originalIMP=%p",
           NSStringFromSelector(selector), isClassMethod ? @"CLASS" : @"INSTANCE", types ?: "(null)", original);

    if (!original) return;
    if (original == (IMP)ZARHookUpdateUndoMessageContent) {
        ZARUndoProbeInstalled = YES;
        return;
    }
    if (!types || strcmp(types, "v24@0:8@16") != 0) {
        ZARLog(@"[ZAR-RECALL] unexpected type encoding=%s; abort", types ?: "(null)");
        return;
    }

    ZAROriginalUpdateUndoMessageContent = (void (*)(id, SEL, id))original;
    method_setImplementation(targetMethod, (IMP)ZARHookUpdateUndoMessageContent);
    ZARUndoProbeInstalled = YES;
    ZARLog(@"[ZAR-RECALL] FINAL HOOK INSTALLED: UndoChatProcessor updateUndoMessageContent: (%@ METHOD)", isClassMethod ? @"CLASS" : @"INSTANCE");
}

void ZARRunMessageTrace(void)
{
    ZARLog(@"===== ZolaAntiRecall FINAL RECALL INTERCEPT =====");
    ZARLog(@"Process=%@ PID=%d", NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ZARInstallDiffProbe();
    });
}

NSString *ZARDiagnosticText(void)
{
    NSString *text = [NSString stringWithContentsOfFile:ZARLogPath() encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return @"暂无探测日志。请点击“重新扫描”。";
    if (text.length > 30000) text = [text substringFromIndex:text.length - 30000];
    return text;
}

void ZARInstallMessageTrace(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        ZARRunMessageTrace();
    });
}
