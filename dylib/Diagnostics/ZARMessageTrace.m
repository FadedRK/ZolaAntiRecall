#import "ZARMessageTrace.h"
#import "../Core/ZARLogger.h"
#import <objc/runtime.h>
#import <Foundation/Foundation.h>

static void ZARScanSelectorOnClass(Class cls, SEL sel) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        ZARLog(@"SCAN target class=%@ selector=%@ NOT FOUND", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }
    ZARLog(@"FOUND target class=%@ selector=%@ types=%s imp=%p",
           NSStringFromClass(cls),
           NSStringFromSelector(sel),
           method_getTypeEncoding(method) ?: "(null)",
           method_getImplementation(method));
}

static id ZARSafeValueForKey(id obj, NSString *key) {
    if (!obj || ![obj respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        ZARLog(@"[ZAR-PROBE] KVC exception key=%@", key);
        return nil;
    }
}

static NSString *ZARBoundedDescription(id obj) {
    if (!obj) return @"(nil)";
    NSString *desc = nil;
    @try {
        desc = [obj description];
    } @catch (__unused NSException *e) {
        desc = @"<description threw exception>";
    }
    if (![desc isKindOfClass:[NSString class]]) return @"<non-string description>";
    if (desc.length > 500) desc = [desc substringToIndex:500];
    return desc;
}

static void ZARProbeUndoMessageContent(id self, SEL _cmd, id arg) {
    ZARLog(@"[ZAR-PROBE] === updateUndoMessageContent TRIGGERED ===");
    ZARLog(@"[ZAR-PROBE] Self Class: %@", NSStringFromClass(object_getClass(self)));
    ZARLog(@"[ZAR-PROBE] Arg: %p", arg);

    if (arg) {
        ZARLog(@"[ZAR-PROBE] Class: %@", NSStringFromClass(object_getClass(arg)));
        ZARLog(@"[ZAR-PROBE] Superclass: %@", NSStringFromClass(class_getSuperclass(object_getClass(arg))));
        ZARLog(@"[ZAR-PROBE] Desc: %@", ZARBoundedDescription(arg));

        id value = ZARSafeValueForKey(arg, @"messageId");
        if (value) ZARLog(@"[ZAR-PROBE] messageId: %@", value);

        value = ZARSafeValueForKey(arg, @"message");
        if (value) ZARLog(@"[ZAR-PROBE] message: %@", value);

        value = ZARSafeValueForKey(arg, @"status");
        if (value) ZARLog(@"[ZAR-PROBE] status: %@", value);

        value = ZARSafeValueForKey(arg, @"isRecallDelByMySelf");
        if (value) ZARLog(@"[ZAR-PROBE] isRecallDelByMySelf: %@", value);

        if ([arg isKindOfClass:[NSNotification class]]) {
            NSNotification *notif = (NSNotification *)arg;
            ZARLog(@"[ZAR-PROBE] Notif Name: %@", notif.name);
            ZARLog(@"[ZAR-PROBE] Notif UserInfo: %@", notif.userInfo ?: @{});
        }
    } else {
        ZARLog(@"[ZAR-PROBE] Triggered but arg is nil!");
    }

    ZARLog(@"[ZAR-PROBE] ========================================");

    SEL alias = sel_registerName("zar_orig_updateUndoMessageContent:");
    void (*orig)(id, SEL, id) =
        (void (*)(id, SEL, id))[self methodForSelector:alias];
    if (orig) {
        orig(self, alias, arg);
    } else {
        ZARLog(@"[ZAR-PROBE] ERROR: original implementation alias not found");
    }
}

static void ZARInstallProbeHook(void) {
    Class cls = NSClassFromString(@"UndoChatProcessor");
    if (!cls) {
        ZARLog(@"[ZAR-PROBE] UndoChatProcessor not found");
        return;
    }

    SEL sel = NSSelectorFromString(@"updateUndoMessageContent:");
    SEL alias = sel_registerName("zar_orig_updateUndoMessageContent:");

    ZARScanSelectorOnClass(cls, sel);

    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;

    const char *types = method_getTypeEncoding(method);
    if (!types || strcmp(types, "v24@0:8@16") != 0) {
        ZARLog(@"[ZAR-PROBE] SKIP type mismatch selector=%@ types=%s expected=v24@0:8@16",
               NSStringFromSelector(sel), types ?: "(null)");
        return;
    }

    if (class_getInstanceMethod(cls, alias)) {
        ZARLog(@"[ZAR-PROBE] hook already installed");
        return;
    }

    class_addMethod(cls, alias, method_getImplementation(method), types);
    method_setImplementation(method, (IMP)ZARProbeUndoMessageContent);
    ZARLog(@"[ZAR-PROBE] HOOKED class=%@ selector=%@ types=%s alias=%@",
           NSStringFromClass(cls), NSStringFromSelector(sel), types, NSStringFromSelector(alias));
}

void ZARRunMessageTrace(void) {
    ZARLog(@"===== ZolaAntiRecall parameter probe =====");
    ZARLog(@"Process=%@ PID=%d", NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier);
    ZARInstallProbeHook();
    ZARLog(@"[ZAR-PROBE] READ-ONLY ONLY: updateUndoMessageContent:; original is always called");
}

NSString *ZARDiagnosticText(void) {
    NSString *text = [NSString stringWithContentsOfFile:ZARLogPath() encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return @"暂无探测日志。请点击“重新扫描”。";
    if (text.length > 30000) text = [text substringFromIndex:text.length - 30000];
    return text;
}

void ZARInstallMessageTrace(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ZARRunMessageTrace();
    });
}
