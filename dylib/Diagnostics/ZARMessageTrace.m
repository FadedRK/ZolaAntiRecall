#import "ZARMessageTrace.h"
#import "../Core/ZARLogger.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void (*ZAROriginalUpdateUndoMessageContent)(id, SEL, id) = NULL;
static BOOL ZARUndoProbeInstalled = NO;

static NSString *ZARSafeDescription(id obj) {
    if (!obj) return @"(nil)";

    @try {
        NSString *desc = [obj description];
        if (![desc isKindOfClass:[NSString class]]) {
            return @"<non-string description>";
        }
        return desc.length > 1000 ? [desc substringToIndex:1000] : desc;
    } @catch (__unused NSException *exception) {
        return @"<description exception>";
    }
}

static id ZARSafeMessageId(id obj) {
    if (!obj) return nil;

    @try {
        SEL selector = NSSelectorFromString(@"messageId");
        if (![obj respondsToSelector:selector]) return nil;
        return [obj valueForKey:@"messageId"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void ZARHookUpdateUndoMessageContent(id self, SEL _cmd, id arg)
{
    @autoreleasepool {
        ZARLog(@"[ZAR-PROBE] ===== updateUndoMessageContent: TRIGGERED =====");

        if (arg) {
            Class argClass = object_getClass(arg);
            ZARLog(@"[ZAR-PROBE] arg class = %@",
                   argClass ? NSStringFromClass(argClass) : @"(nil)");
            ZARLog(@"[ZAR-PROBE] arg description = %@",
                   ZARSafeDescription(arg));

            id messageId = ZARSafeMessageId(arg);
            if (messageId) {
                ZARLog(@"[ZAR-PROBE] arg.messageId = %@", messageId);
            } else {
                ZARLog(@"[ZAR-PROBE] arg.messageId = <unavailable>");
            }
        } else {
            ZARLog(@"[ZAR-PROBE] arg = nil");
        }

        ZARLog(@"[ZAR-PROBE] CALL STACK:");
        NSArray *stack = [NSThread callStackSymbols];
        for (NSString *line in stack) {
            ZARLog(@"[ZAR-PROBE] %@", line);
        }

        ZARLog(@"[ZAR-PROBE] ==========================================");
    }

    // Pure read-only probe: never modify or block Zalo's original logic.
    if (ZAROriginalUpdateUndoMessageContent) {
        ZAROriginalUpdateUndoMessageContent(self, _cmd, arg);
    }
}

static void ZARInstallUndoProbe(void)
{
    if (ZARUndoProbeInstalled) {
        ZARLog(@"[ZAR-PROBE] updateUndoMessageContent: probe already installed");
        return;
    }

    Class cls = objc_getClass("UndoChatProcessor");
    if (!cls) {
        ZARLog(@"[ZAR-PROBE] UndoChatProcessor NOT FOUND after delay");
        return;
    }

    ZARLog(@"[ZAR-PROBE] UndoChatProcessor FOUND: %p", cls);

    SEL selector = NSSelectorFromString(@"updateUndoMessageContent:");
    Method method = class_getInstanceMethod(cls, selector);
    BOOL isClassMethod = NO;

    if (!method) {
        // Fall back to the metaclass for a +class method.
        method = class_getClassMethod(cls, selector);
        if (method) {
            isClassMethod = YES;
            ZARLog(@"[ZAR-PROBE] FOUND as CLASS METHOD!");
        }
    } else {
        ZARLog(@"[ZAR-PROBE] FOUND as INSTANCE METHOD!");
    }

    if (!method) {
        ZARLog(@"[ZAR-PROBE] updateUndoMessageContent: STRICTLY NOT FOUND");
        return;
    }

    const char *types = method_getTypeEncoding(method);
    IMP original = method_getImplementation(method);

    ZARLog(@"[ZAR-PROBE] selector=%@ methodKind=%@ types=%s originalIMP=%p",
           NSStringFromSelector(selector),
           isClassMethod ? @"CLASS" : @"INSTANCE",
           types ?: "(null)",
           original);

    if (!original) {
        ZARLog(@"[ZAR-PROBE] Abort: original IMP is nil");
        return;
    }

    if (original == (IMP)ZARHookUpdateUndoMessageContent) {
        ZARUndoProbeInstalled = YES;
        ZARLog(@"[ZAR-PROBE] probe already points to our hook");
        return;
    }

    // Expected signature confirmed by static analysis: v24@0:8@16.
    if (!types || strcmp(types, "v24@0:8@16") != 0) {
        ZARLog(@"[ZAR-PROBE] WARNING: unexpected type encoding=%s; skip hook",
               types ?: "(null)");
        return;
    }

    ZAROriginalUpdateUndoMessageContent =
        (void (*)(id, SEL, id))original;

    method_setImplementation(method, (IMP)ZARHookUpdateUndoMessageContent);
    ZARUndoProbeInstalled = YES;

    ZARLog(@"[ZAR-PROBE] HOOK INSTALLED: UndoChatProcessor updateUndoMessageContent: (%@ METHOD)",
           isClassMethod ? @"CLASS" : @"INSTANCE");
}

void ZARRunMessageTrace(void)
{
    ZARLog(@"===== ZolaAntiRecall SAFE DELAYED UNDO PROBE =====");
    ZARLog(@"Process=%@ PID=%d",
           NSProcessInfo.processInfo.processName,
           NSProcessInfo.processInfo.processIdentifier);

    // Wait for Zalo's business classes to finish loading into the Objective-C runtime.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ZARInstallUndoProbe();
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
