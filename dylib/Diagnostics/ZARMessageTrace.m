#import "ZARMessageTrace.h"
#import "../Core/ZARLogger.h"
#import "../Settings/ZARSettings.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/lock.h>

static void (*ZAROriginalUpdateUndoMessageContent)(id, SEL, id) = NULL;
static BOOL ZARUndoProbeInstalled = NO;

static NSMutableDictionary *ZARRecallOriginalMessageCache;
static NSMutableDictionary *ZARRecallContentSnapshotCache;
static os_unfair_lock ZARRecallCacheLock = OS_UNFAIR_LOCK_INIT;

static id ZARSafeGetValue(id target, NSString *key)
{
    if (!target || !key) return nil;
    @try { return [target valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static NSString *ZARSafeStringValue(id value)
{
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:[NSString class]]) return value;
    @try {
        NSString *stringValue = [value stringValue];
        if ([stringValue isKindOfClass:[NSString class]]) return stringValue;
    } @catch (__unused NSException *exception) {}
    return nil;
}

static NSString *ZARSafeDescription(id obj)
{
    if (!obj) return @"(nil)";
    @try {
        NSString *desc = [obj description];
        if (![desc isKindOfClass:[NSString class]]) return @"<non-string description>";
        return desc.length > 1000 ? [desc substringToIndex:1000] : desc;
    } @catch (__unused NSException *exception) { return @"<description exception>"; }
}

static id ZARSafeMessageId(id obj) { return ZARSafeGetValue(obj, @"messageId"); }

static NSString *ZARCacheKeyForMessageId(id messageId)
{
    if (!messageId) return nil;
    NSString *stringValue = ZARSafeStringValue(messageId);
    if (stringValue.length) return [NSString stringWithFormat:@"s:%@", stringValue];
    return [NSString stringWithFormat:@"o:%@", ZARSafeDescription(messageId)];
}

static void ZAREnsureRecallCache(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZARRecallOriginalMessageCache = [NSMutableDictionary dictionary];
        ZARRecallContentSnapshotCache = [NSMutableDictionary dictionary];
    });
}

static NSArray<NSString *> *ZARRecallCandidateFields(void)
{
    static NSArray<NSString *> *fields;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fields = @[
            @"attachment", @"attachmentData", @"mediaPath", @"mediaUrl", @"mediaURL",
            @"stickerId", @"stickerID", @"stickerPath", @"caption", @"filePath", @"fileURL",
            @"fileUrl", @"imagePath", @"imageURL", @"imageUrl", @"videoPath", @"videoURL",
            @"audioPath", @"audioURL", @"thumbPath", @"thumbnailPath", @"resourcePath",
            @"localPath", @"localURL", @"content", @"richText", @"rtfMessage", @"extraData",
            @"extraInfo", @"media", @"sticker", @"file", @"image", @"video", @"audio"
        ];
    });
    return fields;
}

static id ZARSafeSnapshotValue(id value)
{
    if (!value || value == [NSNull null]) return nil;
    if ([value conformsToProtocol:@protocol(NSCopying)]) {
        @try {
            id copyValue = [value copy];
            return copyValue ?: value;
        } @catch (__unused NSException *exception) {}
    }
    return ZARSafeDescription(value);
}

static void ZARCacheRecallContentSnapshot(id chatEntity)
{
    id messageId = ZARSafeMessageId(chatEntity);
    NSString *key = ZARCacheKeyForMessageId(messageId);
    if (!key) return;

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    NSString *message = ZARSafeStringValue(ZARSafeGetValue(chatEntity, @"message"));
    if (message.length) snapshot[@"message"] = [message copy];

    for (NSString *field in ZARRecallCandidateFields()) {
        id value = ZARSafeGetValue(chatEntity, field);
        if (!value || value == [NSNull null]) continue;
        id safeValue = ZARSafeSnapshotValue(value);
        if (safeValue) snapshot[field] = safeValue;
    }

    id origin = ZARSafeGetValue(chatEntity, @"originTextRecallMsg");
    if (origin) {
        id safeOrigin = ZARSafeSnapshotValue(origin);
        if (safeOrigin) snapshot[@"originTextRecallMsg"] = safeOrigin;
    }

    os_unfair_lock_lock(&ZARRecallCacheLock);
    if (snapshot.count) ZARRecallContentSnapshotCache[key] = snapshot;
    if (message.length) ZARRecallOriginalMessageCache[key] = [message copy];
    os_unfair_lock_unlock(&ZARRecallCacheLock);

    ZARLog(@"[ZAR-RECALL] BEFORE snapshot key=%@ fields=%@", key, snapshot.allKeys);
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

static NSString *ZARLocalizedRecallTag(BOOL isMyRecall, BOOL hasRichContent)
{
    NSString *language = [NSLocale preferredLanguages].firstObject.lowercaseString ?: @"";
    if ([language hasPrefix:@"zh"]) return isMyRecall ? @"【你已撤回】" : (hasRichContent ? @"【内容已被对方撤回】" : @"【已被对方撤回】");
    if ([language hasPrefix:@"vi"]) return isMyRecall ? @"【Bạn đã thu hồi】" : (hasRichContent ? @"【Nội dung đã bị đối phương thu hồi】" : @"【Đã bị đối phương thu hồi】");
    return isMyRecall ? @"【You recalled this message】" : (hasRichContent ? @"【Content recalled by the other person】" : @"【Recalled by the other person】");
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

static BOOL ZARHasRichContent(id chatEntity)
{
    for (NSString *field in ZARRecallCandidateFields()) {
        id value = ZARSafeGetValue(chatEntity, field);
        if (!value || value == [NSNull null]) continue;
        NSString *name = field.lowercaseString;
        if ([name containsString:@"sticker"] || [name containsString:@"attach"] || [name containsString:@"media"] || [name containsString:@"image"] || [name containsString:@"video"] || [name containsString:@"audio"] || [name containsString:@"file"] || [name containsString:@"rich"] || [name containsString:@"rtf"]) return YES;
    }
    return NO;
}

static NSString *ZARRecallTextForOther(id chatEntity)
{
    id messageId = ZARSafeMessageId(chatEntity);
    NSString *currentMessage = ZARSafeStringValue(ZARSafeGetValue(chatEntity, @"message"));
    if (currentMessage.length) return currentMessage;
    return ZARCachedOriginalMessage(messageId);
}

static NSString *ZARRecallTextForMyself(id chatEntity)
{
    NSString *origin = ZARSafeStringValue(ZARSafeGetValue(chatEntity, @"originTextRecallMsg"));
    if (origin.length) return origin;
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

static void ZARHandleRecallWithoutOriginal(id self, SEL _cmd, id chatEntity)
{
    if (!chatEntity) {
        if (ZAROriginalUpdateUndoMessageContent) ZAROriginalUpdateUndoMessageContent(self, _cmd, chatEntity);
        return;
    }

    BOOL isMyRecall = ZARIsRecallDelByMySelf(chatEntity);

    // Strict native pass-through when the user disables showing their own recalled messages.
    if (isMyRecall && ![ZARSettings sharedInstance].showMyRecallEnabled) {
        ZARLog(@"[ZAR-RECALL] my recall display disabled -> ORIGINAL PASS-THROUGH");
        if (ZAROriginalUpdateUndoMessageContent) ZAROriginalUpdateUndoMessageContent(self, _cmd, chatEntity);
        return;
    }

    // Capture BEFORE content before Zalo's original mutation can erase it.
    ZARCacheRecallContentSnapshot(chatEntity);

    NSString *originalMessage = isMyRecall ? ZARRecallTextForMyself(chatEntity) : ZARRecallTextForOther(chatEntity);
    BOOL hasRichContent = ZARHasRichContent(chatEntity);
    NSString *tag = ZARLocalizedRecallTag(isMyRecall, hasRichContent);
    NSString *taggedMessage = ZARTaggedMessage(originalMessage, tag);

    if (!taggedMessage.length && hasRichContent) {
        // Keep the existing media/sticker/file fields in ChatEntity and avoid orig.
        taggedMessage = tag;
        ZARLog(@"[ZAR-RECALL] rich-content recall: message empty; preserve attachment fields, tag=%@", tag);
    }

    if (!taggedMessage.length) {
        ZARLog(@"[ZAR-RECALL] original content unavailable -> ORIGINAL");
        if (ZAROriginalUpdateUndoMessageContent) ZAROriginalUpdateUndoMessageContent(self, _cmd, chatEntity);
        return;
    }

    ZARLog(@"[ZAR-RECALL] ===== INTERCEPT updateUndoMessageContent: =====");
    ZARLog(@"[ZAR-RECALL] isMyRecall=%@ showMyRecall=%@ richContent=%@ tag=%@", isMyRecall ? @"YES" : @"NO", [ZARSettings sharedInstance].showMyRecallEnabled ? @"YES" : @"NO", hasRichContent ? @"YES" : @"NO", tag);
    ZARLog(@"[ZAR-RECALL] BLOCK ORIGINAL; preserve entity content");

    BOOL messageUpdated = ZARSetMessageSafely(chatEntity, taggedMessage);
    if (messageUpdated) ZARLog(@"[ZAR-RECALL] ChatEntity memory updated; no private UI method invoked");
    ZARLog(@"[ZAR-RECALL] ===== INTERCEPT EXIT =====");
}

static void ZARHookUpdateUndoMessageContent(id self, SEL _cmd, id chatEntity)
{
    @autoreleasepool { ZARHandleRecallWithoutOriginal(self, _cmd, chatEntity); }
}

static void ZARInstallDiffProbe(void)
{
    if (ZARUndoProbeInstalled) { ZARLog(@"[ZAR-RECALL] hook already installed"); return; }

    Class targetClass = objc_getClass("UndoChatProcessor");
    if (!targetClass) { ZARLog(@"[ZAR-RECALL] UndoChatProcessor NOT FOUND after delay"); return; }

    SEL selector = NSSelectorFromString(@"updateUndoMessageContent:");
    Method targetMethod = class_getInstanceMethod(targetClass, selector);
    BOOL isClassMethod = NO;
    if (!targetMethod) {
        targetMethod = class_getClassMethod(targetClass, selector);
        if (targetMethod) { isClassMethod = YES; ZARLog(@"[ZAR-RECALL] FOUND as CLASS METHOD!"); }
    } else {
        ZARLog(@"[ZAR-RECALL] FOUND as INSTANCE METHOD!");
    }
    if (!targetMethod) { ZARLog(@"[ZAR-RECALL] updateUndoMessageContent: STRICTLY NOT FOUND"); return; }

    const char *types = method_getTypeEncoding(targetMethod);
    IMP original = method_getImplementation(targetMethod);
    ZARLog(@"[ZAR-RECALL] selector=%@ methodKind=%@ types=%s originalIMP=%p", NSStringFromSelector(selector), isClassMethod ? @"CLASS" : @"INSTANCE", types ?: "(null)", original);
    if (!original) return;
    if (original == (IMP)ZARHookUpdateUndoMessageContent) { ZARUndoProbeInstalled = YES; return; }
    if (!types || strcmp(types, "v24@0:8@16") != 0) { ZARLog(@"[ZAR-RECALL] unexpected type encoding=%s; abort", types ?: "(null)"); return; }

    ZAROriginalUpdateUndoMessageContent = (void (*)(id, SEL, id))original;
    method_setImplementation(targetMethod, (IMP)ZARHookUpdateUndoMessageContent);
    ZARUndoProbeInstalled = YES;
    ZARLog(@"[ZAR-RECALL] FINAL HOOK INSTALLED: UndoChatProcessor updateUndoMessageContent: (%@ METHOD)", isClassMethod ? @"CLASS" : @"INSTANCE");
}

void ZARRunMessageTrace(void)
{
    ZARLog(@"===== ZolaAntiRecall FINAL RECALL INTERCEPT =====");
    ZARLog(@"Process=%@ PID=%d", NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ ZARInstallDiffProbe(); });
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
    dispatch_async(dispatch_get_main_queue(), ^{ ZARRunMessageTrace(); });
}
