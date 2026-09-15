#import "ZARMessageTrace.h"
#import "../Core/ZARLogger.h"
#import <objc/runtime.h>

static NSArray<NSString *> *ZARKeywords(void) {
    return @[
        @"handleRecallMessageNotification:",
        @"_handleRecallWithData:",
        @"onActionRecallMessages:",
        @"processAfterRecallMessageSuccess:",
        @"proccessUndoInMediaStoreWithMessageId:isGroup:isOwnerRecall:",
        @"updateDBWhenRecalledChats:completion:",
        @"set_recallTime:",
        @"setRecallTime:",
        @"setMessage:",
        @"setStatus:",
        @"recall:"
    ];
}

static void ZARScanSelector(SEL sel) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return;
    count = objc_getClassList(classes, count);
    NSUInteger matches = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            Method m = methods[j];
            if (method_getName(m) != sel) continue;
            matches++;
            const char *types = method_getTypeEncoding(m);
            ZARLog(@"FOUND class=%@ selector=%@ directImplementation=YES types=%s imp=%p",
                   NSStringFromClass(cls), NSStringFromSelector(sel), types ?: "(null)", method_getImplementation(m));
            break;
        }
        free(methods);
    }
    ZARLog(@"SCAN selector=%@ matches=%lu", NSStringFromSelector(sel), (unsigned long)matches);
    free(classes);
}

static void ZARTraceObjectCall(id self, SEL _cmd, id arg, SEL alias) {
    ZARLog(@"CALL class=%@ selector=%@ argClass=%@ arg=%p",
           NSStringFromClass(object_getClass(self)),
           NSStringFromSelector(_cmd),
           arg ? NSStringFromClass(object_getClass(arg)) : @"(nil)",
           arg);
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))[self methodForSelector:alias];
    if (orig) orig(self, alias, arg);
}

static void ZARHandleRecall(id self, SEL _cmd, id arg) {
    ZARTraceObjectCall(self, _cmd, arg, sel_registerName("zar_orig_handleRecallMessageNotification:"));
}

static BOOL ZARIsOwnerRecallData(id arg) {
    if (![arg isKindOfClass:[NSDictionary class]]) return NO;
    id value = [(NSDictionary *)arg objectForKey:@"isOwnerRecall"];
    if (![value respondsToSelector:@selector(boolValue)]) return NO;
    return [value boolValue];
}

static void ZARHandleRecallWithData(id self, SEL _cmd, id arg) {
    BOOL isOwnerRecall = ZARIsOwnerRecallData(arg);
    ZARLog(@"CALL class=%@ selector=%@ argClass=%@ arg=%p isOwnerRecall=%d",
           NSStringFromClass(object_getClass(self)),
           NSStringFromSelector(_cmd),
           arg ? NSStringFromClass(object_getClass(arg)) : @"(nil)",
           arg,
           isOwnerRecall);
    SEL alias = sel_registerName("zar_orig__handleRecallWithData:");
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))[self methodForSelector:alias];
    if (orig) orig(self, alias, arg);
}

static void ZARUndoObjectBool(id self, SEL _cmd, id messageId, BOOL isGroup, BOOL isOwnerRecall) {
    ZARLog(@"CALL class=%@ selector=%@ messageId=%@ isGroup=%d isOwnerRecall=%d",
           NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd), messageId, isGroup, isOwnerRecall);
    if (isOwnerRecall) {
        ZARLog(@"BLOCKED owner recall at proccessUndoInMediaStore...");
        return;
    }
    SEL alias = sel_registerName("zar_orig_proccessUndoInMediaStoreWithMessageId:isGroup:isOwnerRecall:");
    void (*orig)(id, SEL, id, BOOL, BOOL) = (void (*)(id, SEL, id, BOOL, BOOL))[self methodForSelector:alias];
    if (orig) orig(self, alias, messageId, isGroup, isOwnerRecall);
}

static void ZARUndoObjectChar(id self, SEL _cmd, id messageId, BOOL isGroup, BOOL isOwnerRecall) {
    ZARUndoObjectBool(self, _cmd, messageId, isGroup, isOwnerRecall);
}

static void ZARUndoQBool(id self, SEL _cmd, long long messageId, BOOL isGroup, BOOL isOwnerRecall) {
    ZARLog(@"CALL class=%@ selector=%@ messageId=%lld isGroup=%d isOwnerRecall=%d",
           NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd), messageId, isGroup, isOwnerRecall);
    if (isOwnerRecall) {
        ZARLog(@"BLOCKED owner recall at proccessUndoInMediaStore...");
        return;
    }
    SEL alias = sel_registerName("zar_orig_proccessUndoInMediaStoreWithMessageId:isGroup:isOwnerRecall:");
    void (*orig)(id, SEL, long long, BOOL, BOOL) = (void (*)(id, SEL, long long, BOOL, BOOL))[self methodForSelector:alias];
    if (orig) orig(self, alias, messageId, isGroup, isOwnerRecall);
}

static void ZARInstallDirectHook(Class cls, SEL sel, SEL alias, IMP replacement, const char *expectedTypes) {
    if (!cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method method = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { method = methods[i]; break; }
    }
    if (!method) { free(methods); return; }
    const char *types = method_getTypeEncoding(method);
    if (!types || strcmp(types, expectedTypes) != 0) {
        ZARLog(@"SKIP hook class=%@ selector=%@ types=%s expected=%s",
               NSStringFromClass(cls), NSStringFromSelector(sel), types ?: "(null)", expectedTypes);
        free(methods);
        return;
    }
    if (class_getInstanceMethod(cls, alias)) { free(methods); return; }
    class_addMethod(cls, alias, method_getImplementation(method), types);
    method_setImplementation(method, replacement);
    ZARLog(@"HOOKED class=%@ selector=%@ types=%s", NSStringFromClass(cls), NSStringFromSelector(sel), types);
    free(methods);
}

static void ZARInstallUndoHooks(void) {
    SEL sel = NSSelectorFromString(@"proccessUndoInMediaStoreWithMessageId:isGroup:isOwnerRecall:");
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * (size_t)count);
    if (!classes) return;
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);
        for (unsigned int j = 0; j < mc; j++) {
            Method m = methods[j];
            if (method_getName(m) != sel) continue;
            const char *types = method_getTypeEncoding(m);
            SEL alias = sel_registerName("zar_orig_proccessUndoInMediaStoreWithMessageId:isGroup:isOwnerRecall:");
            if (!strcmp(types, "v32@0:8@16B24B25")) {
                ZARInstallDirectHook(cls, sel, alias, (IMP)ZARUndoObjectBool, types);
            } else if (!strcmp(types, "v32@0:8@16c24c25")) {
                ZARInstallDirectHook(cls, sel, alias, (IMP)ZARUndoObjectChar, types);
            } else if (!strcmp(types, "v32@0:8q16B24B25")) {
                ZARInstallDirectHook(cls, sel, alias, (IMP)ZARUndoQBool, types);
            } else {
                ZARLog(@"FOUND undo class=%@ unsupported types=%s", NSStringFromClass(cls), types ?: "(null)");
            }
            break;
        }
        free(methods);
    }
    free(classes);
}

static void ZARInstallObjectHook(Class cls, SEL sel, SEL alias, IMP replacement, const char *expectedTypes) {
    if (!cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method method = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { method = methods[i]; break; }
    }
    if (!method) { free(methods); return; }
    const char *types = method_getTypeEncoding(method);
    if (!types || strcmp(types, expectedTypes) != 0) { free(methods); return; }
    if (class_getInstanceMethod(cls, alias)) { free(methods); return; }
    class_addMethod(cls, alias, method_getImplementation(method), types);
    method_setImplementation(method, replacement);
    free(methods);
}

static void ZARInstallInvocationTrace(void) {
    Class data = NSClassFromString(@"MSDataCoordinator");
    Class cache = NSClassFromString(@"MSLocalCache");
    ZARInstallObjectHook(data, @selector(handleRecallMessageNotification:), sel_registerName("zar_orig_handleRecallMessageNotification:"), (IMP)ZARHandleRecall, "v24@0:8@16");
    ZARInstallObjectHook(cache, @selector(handleRecallMessageNotification:), sel_registerName("zar_orig_handleRecallMessageNotification:"), (IMP)ZARHandleRecall, "v24@0:8@16");
    ZARInstallObjectHook(data, NSSelectorFromString(@"_handleRecallWithData:"), sel_registerName("zar_orig__handleRecallWithData:"), (IMP)ZARHandleRecallWithData, "v24@0:8@16");
    ZARInstallUndoHooks();
}

void ZARRunMessageTrace(void) {
    ZARLog(@"===== ZolaAntiRecall runtime discovery =====");
    ZARLog(@"Process=%@ PID=%d", NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier);
    for (NSString *name in ZARKeywords()) ZARScanSelector(NSSelectorFromString(name));
    ZARInstallInvocationTrace();
    ZARLog(@"EARLY owner-recall undo hook installed");
}

NSString *ZARDiagnosticText(void) {
    NSString *text = [NSString stringWithContentsOfFile:ZARLogPath() encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return @"暂无扫描日志。请点击“重新扫描”。";
    if (text.length > 30000) text = [text substringFromIndex:text.length - 30000];
    return text;
}

void ZARInstallMessageTrace(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ ZARRunMessageTrace(); });
}
