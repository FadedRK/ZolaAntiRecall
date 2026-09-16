#import "ZARMessageTrace.h"
#import "../Core/ZARLogger.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void (*ZAROriginalUpdateUndoMessageContent)(id, SEL, id) = NULL;
static BOOL ZARUndoProbeInstalled = NO;

static id ZARSafeGetValue(id target, NSString *key)
{
    if (!target || !key) return @"<nil>";
    @try {
        id value = [target valueForKey:key];
        return value ? value : @"<null>";
    } @catch (__unused NSException *exception) {
        return @"<Not Found>";
    }
}

static void ZARPrintChatEntityState(NSString *phase, id chatEntity)
{
    ZARLog(@"[ZAR-DIFF] ========== %@ ==========", phase);
    ZARLog(@"[ZAR-DIFF] messageId            = %@", ZARSafeGetValue(chatEntity, @"messageId"));
    ZARLog(@"[ZAR-DIFF] message              = %@", ZARSafeGetValue(chatEntity, @"message"));
    ZARLog(@"[ZAR-DIFF] originTextRecallMsg  = %@", ZARSafeGetValue(chatEntity, @"originTextRecallMsg"));
    ZARLog(@"[ZAR-DIFF] recallTime           = %@", ZARSafeGetValue(chatEntity, @"recallTime"));
    ZARLog(@"[ZAR-DIFF] status               = %@", ZARSafeGetValue(chatEntity, @"status"));
    ZARLog(@"[ZAR-DIFF] _isRecallDelByMySelf = %@", ZARSafeGetValue(chatEntity, @"_isRecallDelByMySelf"));
    ZARLog(@"[ZAR-DIFF] rtfMessage           = %@", ZARSafeGetValue(chatEntity, @"rtfMessage"));
}

static void ZARHookUpdateUndoMessageContent(id self, SEL _cmd, id chatEntity)
{
    @autoreleasepool {
        ZARLog(@"[ZAR-DIFF] ===== updateUndoMessageContent: ENTER =====");
        ZARLog(@"[ZAR-DIFF] self class = %@", self ? NSStringFromClass(object_getClass(self)) : @"<nil>");

        if (!chatEntity) {
            ZARLog(@"[ZAR-DIFF] chatEntity = nil");
            if (ZAROriginalUpdateUndoMessageContent) {
                ZAROriginalUpdateUndoMessageContent(self, _cmd, chatEntity);
            }
            ZARLog(@"[ZAR-DIFF] ===== EXIT =====");
            return;
        }

        ZARLog(@"[ZAR-DIFF] chatEntity class = %@", NSStringFromClass(object_getClass(chatEntity)));

        ZARPrintChatEntityState(@"BEFORE", chatEntity);

        ZARLog(@"[ZAR-DIFF] ========== EXECUTING ORIGINAL ==========");
        if (ZAROriginalUpdateUndoMessageContent) {
            @try {
                ZAROriginalUpdateUndoMessageContent(self, _cmd, chatEntity);
            } @catch (NSException *exception) {
                ZARLog(@"[ZAR-DIFF] ORIGINAL EXCEPTION: %@", exception);
            }
        } else {
            ZARLog(@"[ZAR-DIFF] ERROR: original IMP is NULL");
        }

        ZARPrintChatEntityState(@"AFTER", chatEntity);
        ZARLog(@"[ZAR-DIFF] ===== updateUndoMessageContent: EXIT =====");
    }
}

static void ZARInstallDiffProbe(void)
{
    if (ZARUndoProbeInstalled) {
        ZARLog(@"[ZAR-DIFF] probe already installed");
        return;
    }

    Class targetClass = objc_getClass("UndoChatProcessor");
    if (!targetClass) {
        ZARLog(@"[ZAR-DIFF] UndoChatProcessor NOT FOUND after delay");
        return;
    }

    ZARLog(@"[ZAR-DIFF] UndoChatProcessor FOUND: %p", targetClass);

    SEL selector = NSSelectorFromString(@"updateUndoMessageContent:");
    Method targetMethod = class_getInstanceMethod(targetClass, selector);
    BOOL isClassMethod = NO;

    if (!targetMethod) {
        targetMethod = class_getClassMethod(targetClass, selector);
        if (targetMethod) {
            isClassMethod = YES;
            ZARLog(@"[ZAR-DIFF] FOUND as CLASS METHOD!");
        }
    } else {
        ZARLog(@"[ZAR-DIFF] FOUND as INSTANCE METHOD!");
    }

    if (!targetMethod) {
        ZARLog(@"[ZAR-DIFF] updateUndoMessageContent: STRICTLY NOT FOUND");
        return;
    }

    const char *types = method_getTypeEncoding(targetMethod);
    IMP original = method_getImplementation(targetMethod);

    ZARLog(@"[ZAR-DIFF] selector=%@ methodKind=%@ types=%s originalIMP=%p",
           NSStringFromSelector(selector),
           isClassMethod ? @"CLASS" : @"INSTANCE",
           types ?: "(null)",
           original);

    if (!original) {
        ZARLog(@"[ZAR-DIFF] original IMP is NULL; abort");
        return;
    }

    if (original == (IMP)ZARHookUpdateUndoMessageContent) {
        ZARUndoProbeInstalled = YES;
        ZARLog(@"[ZAR-DIFF] probe already points to our hook");
        return;
    }

    if (!types || strcmp(types, "v24@0:8@16") != 0) {
        ZARLog(@"[ZAR-DIFF] unexpected type encoding=%s; abort", types ?: "(null)");
        return;
    }

    ZAROriginalUpdateUndoMessageContent = (void (*)(id, SEL, id))original;
    method_setImplementation(targetMethod, (IMP)ZARHookUpdateUndoMessageContent);
    ZARUndoProbeInstalled = YES;

    ZARLog(@"[ZAR-DIFF] BEFORE/AFTER probe INSTALLED (%@ METHOD)",
           isClassMethod ? @"CLASS" : @"INSTANCE");
}

void ZARRunMessageTrace(void)
{
    ZARLog(@"===== ZolaAntiRecall BEFORE/AFTER DIFF PROBE =====");
    ZARLog(@"Process=%@ PID=%d",
           NSProcessInfo.processInfo.processName,
           NSProcessInfo.processInfo.processIdentifier);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ZARInstallDiffProbe();
    });
}

NSString *ZARDiagnosticText(void)
{
    NSString *text = [NSString stringWithContentsOfFile:ZARLogPath()
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!text.length) {
        return @"暂无探测日志。请点击“重新扫描”。";
    }

    if (text.length > 30000) {
        text = [text substringFromIndex:text.length - 30000];
    }

    return text;
}

void ZARInstallMessageTrace(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        ZARRunMessageTrace();
    });
}
