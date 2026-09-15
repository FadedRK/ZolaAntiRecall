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

static BOOL ZARIsOwnerRecallEntity(id self) {
    @try {
        id value = [self valueForKey:@"isRecallDelByMySelf"];
        if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    } @catch (__unused NSException *e) {}
    return NO;
}

static NSHashTable *ZARPendingEntities(void) {
    static NSHashTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

static BOOL ZARPendingContains(id obj) {
    @synchronized (ZARPendingEntities()) {
        return [ZARPendingEntities() containsObject:obj];
    }
}

static void ZARPendingAdd(id obj) {
    @synchronized (ZARPendingEntities()) {
        [ZARPendingEntities() addObject:obj];
    }
}

static void ZARPendingRemove(id obj) {
    @synchronized (ZARPendingEntities()) {
        [ZARPendingEntities() removeObject:obj];
    }
}

static void ZARSetRecallTime(id self, SEL _cmd, long long value) {
    BOOL owner = ZARIsOwnerRecallEntity(self);
    ZARLog(@"CALL class=%@ selector=%@ value=%lld isRecallDelByMySelf=%d",
           NSStringFromClass(object_getClass(self)),
           NSStringFromSelector(_cmd), value, owner);
    if (owner) {
        ZARPendingAdd(self);
        ZARLog(@"MARK pending owner recall entity=%p", self);
    }
    SEL alias = sel_registerName("zar_orig_set_recallTime:");
    void (*orig)(id, SEL, long long) = (void (*)(id, SEL, long long))[self methodForSelector:alias];
    if (orig) orig(self, alias, value);
}

static void ZARSetMessage(id self, SEL _cmd, id value) {
    BOOL pending = ZARPendingContains(self);
    NSString *incoming = [value isKindOfClass:[NSString class]] ? value : nil;
    if (pending) {
        id original = nil;
        @try { original = [self valueForKey:@"originTextRecallMsg"]; } @catch (__unused NSException *e) {}
        if ([original isKindOfClass:[NSString class]] && [original length] > 0 && incoming.length > 0) {
            ZARLog(@"OWNER RECALL setMessage intercepted entity=%p incoming=%@ original=%@", self, incoming, original);
            ZARPendingRemove(self);
            SEL alias = sel_registerName("zar_orig_setMessage:");
            void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))[self methodForSelector:alias];
            if (orig) orig(self, alias, original);
            return;
        }
    }
    SEL alias = sel_registerName("zar_orig_setMessage:");
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))[self methodForSelector:alias];
    if (orig) orig(self, alias, value);
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

static void ZARInstallObjectHook(Class cls, SEL sel, SEL alias, IMP replacement, const char *expectedTypes) {
    if (!cls) return;
    Method method = NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            method = methods[i];
            break;
        }
    }
    if (!method) {
        free(methods);
        ZARLog(@"SKIP direct hook class=%@ selector=%@ reason=no-direct-method", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }
    const char *types = method_getTypeEncoding(method);
    if (!types || strcmp(types, expectedTypes) != 0) {
        ZARLog(@"SKIP hook class=%@ selector=%@ types=%s expected=%s",
               NSStringFromClass(cls), NSStringFromSelector(sel), types ?: "(null)", expectedTypes);
        free(methods);
        return;
    }
    if (class_getInstanceMethod(cls, alias)) {
        free(methods);
        return;
    }
    class_addMethod(cls, alias, method_getImplementation(method), types);
    method_setImplementation(method, replacement);
    ZARLog(@"HOOKED class=%@ selector=%@ types=%s alias=%@",
           NSStringFromClass(cls), NSStringFromSelector(sel), types, NSStringFromSelector(alias));
    free(methods);
}

static void ZARInstallInvocationTrace(void) {
    Class data = NSClassFromString(@"MSDataCoordinator");
    Class cache = NSClassFromString(@"MSLocalCache");
    Class entity = NSClassFromString(@"ChatEntity");

    ZARInstallObjectHook(data,
                         @selector(handleRecallMessageNotification:),
                         sel_registerName("zar_orig_handleRecallMessageNotification:"),
                         (IMP)ZARHandleRecall,
                         "v24@0:8@16");
    ZARInstallObjectHook(cache,
                         @selector(handleRecallMessageNotification:),
                         sel_registerName("zar_orig_handleRecallMessageNotification:"),
                         (IMP)ZARHandleRecall,
                         "v24@0:8@16");
    ZARInstallObjectHook(data,
                         NSSelectorFromString(@"_handleRecallWithData:"),
                         sel_registerName("zar_orig__handleRecallWithData:"),
                         (IMP)ZARHandleRecallWithData,
                         "v24@0:8@16");
    ZARInstallObjectHook(entity,
                         @selector(set_recallTime:),
                         sel_registerName("zar_orig_set_recallTime:"),
                         (IMP)ZARSetRecallTime,
                         "v24@0:8q16");
    ZARInstallObjectHook(entity,
                         @selector(setMessage:),
                         sel_registerName("zar_orig_setMessage:"),
                         (IMP)ZARSetMessage,
                         "v24@0:8@16");
}

void ZARRunMessageTrace(void) {
    ZARLog(@"===== ZolaAntiRecall runtime discovery =====");
    ZARLog(@"Process=%@ PID=%d", NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier);
    for (NSString *name in ZARKeywords()) {
        ZARScanSelector(NSSelectorFromString(name));
    }
    ZARInstallInvocationTrace();
    ZARLog(@"TARGETED owner-recall mutation hook installed");
}

NSString *ZARDiagnosticText(void) {
    NSString *text = [NSString stringWithContentsOfFile:ZARLogPath() encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return @"暂无扫描日志。请点击“重新扫描”。";
    if (text.length > 30000) text = [text substringFromIndex:text.length - 30000];
    return text;
}

void ZARInstallMessageTrace(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ZARRunMessageTrace();
    });
}
