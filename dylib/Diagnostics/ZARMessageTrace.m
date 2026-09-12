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

static void ZARLogCallStack(NSString *label) {
    NSArray<NSString *> *frames = [NSThread callStackSymbols];
    NSUInteger count = MIN((NSUInteger)16, frames.count);
    if (count == 0) return;
    NSArray<NSString *> *slice = [frames subarrayWithRange:NSMakeRange(0, count)];
    ZARLog(@"STACK %@\n%@", label, [slice componentsJoinedByString:@"\n"]);
}

static void ZARLogRecallDictionary(NSString *label, NSDictionary *dict) {
    if (!dict) {
        ZARLog(@"%@ dictionary=(nil)", label);
        return;
    }

    id messageId = dict[@"messageId"];
    id isGroup = dict[@"isGroup"];
    id isOwnerRecall = dict[@"isOwnerRecall"];

    ZARLog(@"%@ messageId=%@ isGroup=%@ isOwnerRecall=%@ keys=%@",
           label,
           messageId ?: @"(nil)",
           isGroup ?: @"(nil)",
           isOwnerRecall ?: @"(nil)",
           [[dict allKeys] valueForKey:@"description"]);
}

static void ZARLogRecallArgument(NSString *label, id arg) {
    if (!arg) {
        ZARLog(@"%@ arg=(nil)", label);
        return;
    }

    NSString *className = NSStringFromClass(object_getClass(arg));

    if ([arg isKindOfClass:[NSDictionary class]]) {
        ZARLogRecallDictionary(label, (NSDictionary *)arg);
        return;
    }

    if ([arg isKindOfClass:[NSNotification class]]) {
        NSNotification *note = (NSNotification *)arg;
        ZARLog(@"%@ notificationName=%@", label, note.name);
        if ([note.userInfo isKindOfClass:[NSDictionary class]]) {
            ZARLogRecallDictionary([label stringByAppendingString:@" userInfo"], note.userInfo);
        }
        return;
    }

    if ([arg isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)arg;
        ZARLog(@"%@ arrayClass=%@ count=%lu", label, className, (unsigned long)array.count);
        NSUInteger index = 0;
        for (id item in array) {
            if (index >= 8) {
                ZARLog(@"%@ ... truncated at 8 items", label);
                break;
            }
            ZARLog(@"%@ item[%lu] class=%@ desc=%@", label,
                   (unsigned long)index,
                   item ? NSStringFromClass(object_getClass(item)) : @"(nil)",
                   item ? [item description] : @"(nil)");
            index++;
        }
        return;
    }

    ZARLog(@"%@ argClass=%@ arg=%p desc=%@", label, className, arg, [arg description]);
}

static id ZARSafeKVC(id obj, NSString *key);

static void ZARTraceObjectCall(id self, SEL _cmd, id arg, SEL alias) {
    NSString *selectorName = NSStringFromSelector(_cmd);
    ZARLog(@"CALL class=%@ selector=%@ argClass=%@ arg=%p",
           NSStringFromClass(object_getClass(self)),
           selectorName,
           arg ? NSStringFromClass(object_getClass(arg)) : @"(nil)",
           arg);

    if ([selectorName isEqualToString:@"handleRecallMessageNotification:"]) {
        ZARLogRecallArgument(@"RECALL-NOTIFICATION", arg);
        if ([arg isKindOfClass:[NSNotification class]]) {
            ZARLogCallStack(@"handleRecallMessageNotification:");
        }
    } else if ([selectorName isEqualToString:@"_handleRecallWithData:"]) {
        ZARLogRecallArgument(@"RECALL-DATA", arg);
        ZARLogCallStack(@"_handleRecallWithData:");
    }

    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))[self methodForSelector:alias];
    if (orig) orig(self, alias, arg);
}

static id ZARSafeKVC(id obj, NSString *key) {
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void ZARDumpChatEntity(id obj, NSString *prefix) {
    if (!obj) return;
    ZARLog(@"%@ ChatEntity=%p class=%@", prefix, obj, NSStringFromClass(object_getClass(obj)));

    NSArray<NSString *> *keys = @[
        @"messageId", @"messageID", @"msgId", @"msgID",
        @"recallTime", @"recall_time", @"isRecall", @"isRecalled",
        @"isOwnerRecall", @"ownerRecall", @"message_recall",
        @"recalled_message", @"chatId", @"conversationId",
        @"_isRecallDelByMySelf", @"_deleted", @"status",
        @"_messagetype", @"_originTextRecallMsg"
    ];

    for (NSString *key in keys) {
        id value = ZARSafeKVC(obj, key);
        if (value) {
            ZARLog(@"%@ KVC %@=%@", prefix, key, value);
        }
    }

    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(object_getClass(obj), &count);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        const char *name = property_getName(props[i]);
        if (name) [names addObject:[NSString stringWithUTF8String:name]];
    }
    free(props);
    ZARLog(@"%@ properties=%@", prefix, names);
}

static void ZARUpdateDBWhenRecalledChats(id self, SEL _cmd, id chats, id completion) {
    ZARLog(@"CALL class=%@ selector=%@ chatsClass=%@ chats=%p completion=%p",
           NSStringFromClass(object_getClass(self)),
           NSStringFromSelector(_cmd),
           chats ? NSStringFromClass(object_getClass(chats)) : @"(nil)",
           chats,
           completion);

    ZARLogRecallArgument(@"RECALL-DB-ARG", chats);

    BOOL blockSelfRecall = NO;
    id target = nil;
    if ([chats isKindOfClass:[NSArray class]] && [(NSArray *)chats count] > 0) {
        target = [(NSArray *)chats firstObject];
        id flag = ZARSafeKVC(target, @"_isRecallDelByMySelf");
        blockSelfRecall = [flag respondsToSelector:@selector(boolValue)] && [flag boolValue];
    }

    if (blockSelfRecall) {
        ZARLog(@"BLOCKED self recall in updateDBWhenRecalledChats:completion: message=%@",
               ZARSafeKVC(target, @"messageId") ?: @"(nil)");
        ZARLogCallStack(@"BLOCKED updateDBWhenRecalledChats:completion:");
        return;
    }

    if ([chats isKindOfClass:[NSArray class]]) {
        NSUInteger index = 0;
        for (id item in (NSArray *)chats) {
            if (index++ >= 4) break;
            ZARDumpChatEntity(item, @"RECALL-DB-ITEM");
        }
    }
    ZARLogCallStack(@"updateDBWhenRecalledChats:completion:");

    void (*orig)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))[self methodForSelector:sel_registerName("zar_orig_updateDBWhenRecalledChats:completion:")];
    if (orig) orig(self, sel_registerName("zar_orig_updateDBWhenRecalledChats:completion:"), chats, completion);
}

static void ZARHandleRecall(id self, SEL _cmd, id arg) {
    BOOL isOwnerRecall = NO;

    if ([arg isKindOfClass:[NSNotification class]]) {
        NSNotification *note = (NSNotification *)arg;
        id flag = note.userInfo[@"isOwnerRecall"];
        isOwnerRecall = [flag respondsToSelector:@selector(boolValue)] && [flag boolValue];
    }

    if (isOwnerRecall) {
        ZARLog(@"BLOCKED self recall notification in handleRecallMessageNotification:");
        ZARLogRecallArgument(@"BLOCKED-RECALL-NOTIFICATION", arg);
        ZARLogCallStack(@"BLOCKED handleRecallMessageNotification:");
        return;
    }

    ZARTraceObjectCall(self, _cmd, arg, sel_registerName("zar_orig_handleRecallMessageNotification:"));
}

static void ZARHandleRecallWithData(id self, SEL _cmd, id arg) {
    ZARTraceObjectCall(self, _cmd, arg, sel_registerName("zar_orig__handleRecallWithData:"));
}

static void ZARSetRecallTime(id self, SEL _cmd, long long value) {
    ZARLog(@"CALL class=%@ selector=%@ value=%lld",
           NSStringFromClass(object_getClass(self)),
           NSStringFromSelector(_cmd), value);

    id selfRecallFlag = ZARSafeKVC(self, @"_isRecallDelByMySelf");
    BOOL isSelfRecall = [selfRecallFlag respondsToSelector:@selector(boolValue)] && [selfRecallFlag boolValue];

    if (isSelfRecall) {
        ZARLog(@"BLOCKED self recall set_recallTime: value=%lld", value);
        ZARLogCallStack(@"BLOCKED set_recallTime:");
        return;
    }

    SEL alias = sel_registerName("zar_orig_set_recallTime:");
    void (*orig)(id, SEL, long long) = (void (*)(id, SEL, long long))[self methodForSelector:alias];
    if (orig) orig(self, alias, value);
}

static void ZARInstallObjectHook(Class cls, SEL sel, SEL alias, IMP replacement, const char *expectedTypes) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    const char *types = method_getTypeEncoding(method);
    if (!types || strcmp(types, expectedTypes) != 0) {
        ZARLog(@"SKIP hook class=%@ selector=%@ types=%s expected=%s",
               NSStringFromClass(cls), NSStringFromSelector(sel), types ?: "(null)", expectedTypes);
        return;
    }
    if (class_getInstanceMethod(cls, alias)) return;
    class_addMethod(cls, alias, method_getImplementation(method), types);
    method_setImplementation(method, replacement);
    ZARLog(@"HOOKED class=%@ selector=%@ types=%s alias=%@",
           NSStringFromClass(cls), NSStringFromSelector(sel), types, NSStringFromSelector(alias));
}

static void ZARInstallInvocationTrace(void) {
    Class data = NSClassFromString(@"MSDataCoordinator");
    Class cache = NSClassFromString(@"MSLocalCache");
    Class entity = NSClassFromString(@"ChatEntity");
    Class conversation = NSClassFromString(@"ConversationModel");

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
    ZARInstallObjectHook(conversation,
                         @selector(updateDBWhenRecalledChats:completion:),
                         sel_registerName("zar_orig_updateDBWhenRecalledChats:completion:"),
                         (IMP)ZARUpdateDBWhenRecalledChats,
                         "v32@0:8@16@?24");
}

void ZARRunMessageTrace(void) {
    ZARLog(@"===== ZolaAntiRecall runtime discovery =====");
    ZARLog(@"Process=%@ PID=%d", NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier);
    for (NSString *name in ZARKeywords()) {
        ZARScanSelector(NSSelectorFromString(name));
    }
    ZARInstallInvocationTrace();
    ZARLog(@"INVOCATION TRACE installed; originals are still called; no recall blocking");
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
