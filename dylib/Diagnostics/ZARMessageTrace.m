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

static void ZARLogReturnAddressProbe(NSString *prefix) {
    void *a0 = __builtin_return_address(0);
    Dl_info i0 = {0};
    if (dladdr(a0, &i0) && i0.dli_fbase) {
        uintptr_t base = (uintptr_t)i0.dli_fbase;
        uintptr_t addr = (uintptr_t)a0;
        ZARLog(@"%@ CURRENT addr=%p image=%s base=0x%lx offset=0x%lx symbol=%s",
               prefix, a0, i0.dli_fname ?: "(null)",
               (unsigned long)base,
               (unsigned long)(addr >= base ? addr - base : 0),
               i0.dli_sname ?: "(null)");
    } else {
        ZARLog(@"%@ CURRENT unresolved addr=%p", prefix, a0);
    }
}

static void ZARRecallTimeBacktrace(id self, SEL _cmd, long long recallTime) {
    ZARLog(@"RECALLTIME class=%@ selector=%@ recallTime=%lld self=%p",
           NSStringFromClass(object_getClass(self)),
           NSStringFromSelector(_cmd),
           recallTime,
           self);

    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    NSUInteger limit = MIN((NSUInteger)10, stack.count);
    ZARLog(@"RECALLTIME BACKTRACE frames=%lu", (unsigned long)limit);
    for (NSUInteger i = 0; i < limit; i++) {
        ZARLog(@"RECALLTIME #%lu %@", (unsigned long)i, stack[i]);
    }

    SEL alias = sel_registerName("zar_orig_set_recallTime:");
    void (*orig)(id, SEL, long long) = (void (*)(id, SEL, long long))[self methodForSelector:alias];
    if (orig) orig(self, alias, recallTime);
}


static void ZARLogAddressInfo(NSString *prefix, NSUInteger frameIndex) {
    void *address = __builtin_return_address(0);
    Dl_info info = {0};
    if (dladdr(address, &info) && info.dli_fname) {
        uintptr_t base = (uintptr_t)info.dli_fbase;
        uintptr_t addr = (uintptr_t)address;
        uintptr_t offset = addr >= base ? (addr - base) : 0;
        ZARLog(@"%@ DLADDR frame=%lu addr=%p image=%s base=0x%lx offset=0x%lx symbol=%s",
               prefix,
               (unsigned long)frameIndex,
               address,
               info.dli_fname,
               (unsigned long)base,
               (unsigned long)offset,
               info.dli_sname ?: "(null)");
    } else {
        ZARLog(@"%@ DLADDR frame=%lu unresolved addr=%p", prefix, (unsigned long)frameIndex, address);
    }
}

static void ZARLogStackWithPrefix(NSString *prefix) {
    NSArray<NSString *> *stack = [NSThread callStackSymbols];
    NSUInteger limit = MIN((NSUInteger)16, stack.count);
    ZARLog(@"%@ frames=%lu", prefix, (unsigned long)limit);
    for (NSUInteger i = 0; i < limit; i++) {
        ZARLog(@"%@ #%lu %@", prefix, (unsigned long)i, stack[i]);
    }
    // dladdr on the current frame gives us a symbol/image sanity check.
    ZARLogAddressInfo(prefix, 0);
}

static void ZARPBDataReaderRecallTrace(id self, SEL _cmd, const void *buffer) {
    ZARLog(@"[ZALO_PB_RECALL] class=%@ selector=%@ buffer=%p",
           NSStringFromClass(object_getClass(self)),
           NSStringFromSelector(_cmd),
           buffer);
    ZARLog(@"[ZALO_PB_RECALL] thread=%@ main=%d",
           [NSThread currentThread],
           [NSThread isMainThread] ? 1 : 0);
    ZARLogStackWithPrefix(@"[ZALO_PB_RECALL_STACK]");

    SEL alias = sel_registerName("zar_orig_pbdatareader_recall:");
    void (*orig)(id, SEL, const void *) =
        (void (*)(id, SEL, const void *))[self methodForSelector:alias];
    if (orig) orig(self, alias, buffer);
}

static BOOL ZARIsRecallNotification(NSString *name, NSDictionary *userInfo) {
    NSString *lower = name.lowercaseString ?: @"";
    if ([lower containsString:@"recall"]) return YES;
    if (userInfo[@"messageId"] != nil && userInfo[@"isOwnerRecall"] != nil) return YES;
    return NO;
}

static void ZARNotificationPostTrace(id self,
                                     SEL _cmd,
                                     NSString *name,
                                     id object,
                                     NSDictionary *userInfo) {
    if (ZARIsRecallNotification(name, userInfo)) {
        ZARLog(@"[ZALO_NOTIFICATION] name=%@ objectClass=%@ object=%p userInfo=%@",
               name ?: @"(nil)",
               object ? NSStringFromClass(object_getClass(object)) : @"(nil)",
               object,
               userInfo ?: @{});
        ZARLog(@"[ZALO_NOTIFICATION] thread=%@ main=%d",
               [NSThread currentThread],
               [NSThread isMainThread] ? 1 : 0);
        ZARLogStackWithPrefix(@"[ZALO_NOTIFICATION_STACK]");
    }

    SEL alias = sel_registerName("zar_orig_postNotificationName:object:userInfo:");
    void (*orig)(id, SEL, NSString *, id, NSDictionary *) =
        (void (*)(id, SEL, NSString *, id, NSDictionary *))[self methodForSelector:alias];
    if (orig) orig(self, alias, name, object, userInfo);
}

static void ZARInstallRecallProbeHooks(void) {
    Class reader = NSClassFromString(@"PBDataReader");
    ZARInstallDirectHook(reader,
                         @selector(recall:),
                         sel_registerName("zar_orig_pbdatareader_recall:"),
                         (IMP)ZARPBDataReaderRecallTrace,
                         "v24@0:8r^{?=QQ}16");

    ZARInstallDirectHook([NSNotificationCenter class],
                         @selector(postNotificationName:object:userInfo:),
                         sel_registerName("zar_orig_postNotificationName:object:userInfo:"),
                         (IMP)ZARNotificationPostTrace,
                         "v40@0:8@16@24@32");
}

static void ZARInstallRecallTimeBacktraceHook(void) {
    Class chatEntity = NSClassFromString(@"ChatEntity");
    if (!chatEntity) {
        ZARLog(@"BACKTRACE hook skipped: ChatEntity not found");
        return;
    }
    ZARInstallDirectHook(chatEntity,
                         @selector(set_recallTime:),
                         sel_registerName("zar_orig_set_recallTime:"),
                         (IMP)ZARRecallTimeBacktrace,
                         "v24@0:8q16");
}

static void ZARInstallInvocationTrace(void) {
    Class data = NSClassFromString(@"MSDataCoordinator");
    Class cache = NSClassFromString(@"MSLocalCache");
    ZARInstallDirectHook(data, @selector(handleRecallMessageNotification:), sel_registerName("zar_orig_handleRecallMessageNotification:"), (IMP)ZARHandleRecall, "v24@0:8@16");
    ZARInstallDirectHook(cache, @selector(handleRecallMessageNotification:), sel_registerName("zar_orig_handleRecallMessageNotification:"), (IMP)ZARHandleRecall, "v24@0:8@16");
    ZARInstallDirectHook(data, NSSelectorFromString(@"_handleRecallWithData:"), sel_registerName("zar_orig__handleRecallWithData:"), (IMP)ZARHandleRecallWithData, "v24@0:8@16");
    ZARInstallRecallTimeBacktraceHook();
    ZARInstallRecallProbeHooks();
}

void ZARRunMessageTrace(void) {
    ZARLog(@"===== ZolaAntiRecall runtime discovery =====");
    ZARLog(@"Process=%@ PID=%d", NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier);
    for (NSString *name in ZARKeywords()) ZARScanSelector(NSSelectorFromString(name));
    ZARInstallInvocationTrace();
    ZARLog(@"READ-ONLY TRACE: set_recallTime + PBDataReader recall: + NSNotificationCenter postNotificationName:object:userInfo:; all originals are called");
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
