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

static NSMutableSet<NSString *> *ZARPendingSelfRecallIDs(void) {
    static NSMutableSet<NSString *> *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        set = [NSMutableSet set];
    });
    return set;
}

static NSString *ZARMessageIDKey(id messageId) {
    if (!messageId) return nil;
    @try {
        NSString *desc = [messageId description];
        return desc.length ? desc : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
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
    if ([chats isKindOfClass:[NSArray class]]) {
        NSUInteger index = 0;
        for (id item in (NSArray *)chats) {
            if (index++ >= 4) break;
            ZARDumpChatEntity(item, @"RECALL-DB-ITEM");
        }
    }
    ZARLogCallStack(@"updateDBWhenRecalledChats:completion:");

    SEL alias = sel_registerName("zar_orig_updateDBWhenRecalledChats:completion:");
    void (*orig)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))[self methodForSelector:alias];
    if (orig) orig(self, alias, chats, completion);
}

static void ZARHandleRecall(id self, SEL _cmd, id arg) {
    ZARTraceObjectCall(self, _cmd, arg, sel_registerName("zar_orig_handleRecallMessageNotification:"));
}

static void ZARHandleRecallWithData(id self, SEL _cmd, id arg) {
    ZARTraceObjectCall(self, _cmd, arg, sel_registerName("zar_orig__handleRecallWithData:"));
}

static void ZARSetRecallTime(id self, SEL _cmd, long long value) {
    id selfRecallFlag = ZARSafeKVC(self, @"_isRecallDelByMySelf");
    id messageId = ZARSafeKVC(self, @"messageId");
    NSString *key = ZARMessageIDKey(messageId);
    BOOL isSelfRecall = [selfRecallFlag respondsToSelector:@selector(boolValue)] && [selfRecallFlag boolValue];

    ZARLog(@"CALL class=%@ selector=%@ value=%lld selfRecallFlag=%@ messageId=%@",
           NSStringFromClass(object_getClass(self)),
           NSStringFromSelector(_cmd),
           value,
           selfRecallFlag ?: @"(nil)",
           messageId ?: @"(nil)");

    if (isSelfRecall && key.length) {
        @synchronized (ZARPendingSelfRecallIDs()) {
            [ZARPendingSelfRecallIDs() addObject:key];
        }
        ZARLog(@"MARKED pending self recall messageId=%@", messageId);
    }
    ZARLogCallStack(@"set_recallTime:");

    SEL alias = sel_registerName("zar_orig_set_recallTime:");
    void (*orig)(id, SEL, long long) =
        (void (*)(id, SEL, long long))[self methodForSelector:alias];
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

static NSString *ZARStateAliasForSelector(SEL sel) {
    NSString *name = NSStringFromSelector(sel);
    return [@"zar_orig_state_" stringByAppendingString:[name stringByReplacingOccurrencesOfString:@":" withString:@"_"]];
}

static void ZARTraceStateObject(id self, SEL _cmd, id value) {
    ZARLog(@"STATE-CALL class=%@ selector=%@ valueClass=%@ value=%@",
           NSStringFromClass(object_getClass(self)),
           NSStringFromSelector(_cmd),
           value ? NSStringFromClass(object_getClass(value)) : @"(nil)",
           value ?: @"(nil)");
    SEL alias = NSSelectorFromString(ZARStateAliasForSelector(_cmd));
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))[self methodForSelector:alias];
    if (orig) orig(self, alias, value);
}

static void ZARTraceStateBool(id self, SEL _cmd, BOOL value) {
    ZARLog(@"STATE-CALL class=%@ selector=%@ bool=%d",
           NSStringFromClass(object_getClass(self)),
           NSStringFromSelector(_cmd),
           value ? 1 : 0);
    SEL alias = NSSelectorFromString(ZARStateAliasForSelector(_cmd));
    void (*orig)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))[self methodForSelector:alias];
    if (orig) orig(self, alias, value);
}

static BOOL ZARIsRecallPlaceholderMessage(id value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *s = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!s.length) return NO;

    NSSet<NSString *> *known = [NSSet setWithObjects:
        @"Tin nhắn đã được thu hồi",
        @"消息被召回",
        @"This message was recalled",
        @"Message was recalled",
        @"The message was recalled",
        nil
    ];
    if ([known containsObject:s]) return YES;

    NSString *lower = s.lowercaseString;
    return [lower containsString:@"recalled"] || [lower containsString:@"recalled message"];
}

static void ZARTraceSetMessage(id self, SEL _cmd, id value) {
    id flag = ZARSafeKVC(self, @"_isRecallDelByMySelf");
    id messageId = ZARSafeKVC(self, @"messageId");
    NSString *key = ZARMessageIDKey(messageId);
    BOOL selfRecall = [flag respondsToSelector:@selector(boolValue)] && [flag boolValue];
    BOOL pending = NO;

    if (key.length) {
        @synchronized (ZARPendingSelfRecallIDs()) {
            pending = [ZARPendingSelfRecallIDs() containsObject:key];
        }
    }

    ZARLog(@"STATE-CALL class=%@ selector=%@ valueClass=%@ value=%@ selfRecallFlag=%@ pendingSelfRecall=%d messageId=%@",
           NSStringFromClass(object_getClass(self)),
           NSStringFromSelector(_cmd),
           value ? NSStringFromClass(object_getClass(value)) : @"(nil)",
           value ?: @"(nil)",
           flag ?: @"(nil)",
           pending ? 1 : 0,
           messageId ?: @"(nil)");

    if ((selfRecall || pending) && ZARIsRecallPlaceholderMessage(value)) {
        ZARLog(@"BLOCKED recall placeholder setMessage: messageId=%@ value=%@",
               messageId ?: @"(nil)", value ?: @"(nil)");
        ZARLogCallStack(@"BLOCKED setMessage:");
        return;
    }

    SEL alias = NSSelectorFromString(ZARStateAliasForSelector(_cmd));
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))[self methodForSelector:alias];
    if (orig) orig(self, alias, value);
}


static BOOL ZARShouldTraceStateSelector(NSString *name) {
    NSString *lower = name.lowercaseString;
    return [lower hasPrefix:@"set"] &&
           ([lower containsString:@"recall"] ||
            [lower containsString:@"delete"] ||
            [lower containsString:@"status"] ||
            [lower containsString:@"message"] ||
            [lower containsString:@"origintext"]);
}

static void ZARInstallStateMutationTraceForClass(Class cls) {
    if (!cls) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        Method method = methods[i];
        SEL sel = method_getName(method);
        NSString *name = NSStringFromSelector(sel);
        if (!ZARShouldTraceStateSelector(name)) continue;

        const char *types = method_getTypeEncoding(method);
        if (!types) continue;

        NSString *aliasName = ZARStateAliasForSelector(sel);
        SEL alias = NSSelectorFromString(aliasName);
        if (class_getInstanceMethod(cls, alias)) continue;

        IMP replacement = NULL;
        if (strcmp(types, "v24@0:8@16") == 0) {
            replacement = (IMP)ZARTraceStateObject;
        } else if (strcmp(types, "v24@0:8B16") == 0) {
            replacement = (IMP)ZARTraceStateBool;
        } else if (strcmp(types, "v24@0:8q16") == 0 ||
                   strcmp(types, "v24@0:8Q16") == 0) {
            replacement = (IMP)ZARTraceStateLongLong;
        } else {
            ZARLog(@"STATE-SKIP class=%@ selector=%@ types=%s",
                   NSStringFromClass(cls), name, types);
            continue;
        }

        class_addMethod(cls, alias, method_getImplementation(method), types);
        method_setImplementation(method, replacement);
        ZARLog(@"STATE-HOOKED class=%@ selector=%@ types=%s alias=%@",
               NSStringFromClass(cls), name, types, aliasName);
    }
    free(methods);
}

static void ZARScanStateMethodsForClass(Class cls) {
    if (!cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        Method method = methods[i];
        NSString *name = NSStringFromSelector(method_getName(method));
        if (!ZARShouldTraceStateSelector(name)) continue;
        ZARLog(@"STATE-CANDIDATE class=%@ selector=%@ types=%s",
               NSStringFromClass(cls),
               name,
               method_getTypeEncoding(method) ?: "(null)");
    }
    free(methods);
}

static void ZARInstallInvocationTrace(void) {
    Class data = NSClassFromString(@"MSDataCoordinator");
    Class cache = NSClassFromString(@"MSLocalCache");
    Class entity = NSClassFromString(@"ChatEntity");
    Class conversation = NSClassFromString(@"ConversationModel");
    Class singleConversation = NSClassFromString(@"SingleConversationModel");

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
    Method setMessageMethod = class_getInstanceMethod(entity, @selector(setMessage:));
    if (setMessageMethod) {
        const char *types = method_getTypeEncoding(setMessageMethod);
        SEL alias = sel_registerName("zar_orig_state_setMessage_");
        if (types && strcmp(types, "v24@0:8@16") == 0 && !class_getInstanceMethod(entity, alias)) {
            class_addMethod(entity, alias, method_getImplementation(setMessageMethod), types);
            method_setImplementation(setMessageMethod, (IMP)ZARTraceSetMessage);
            ZARLog(@"STATE-HOOKED class=%@ selector=setMessage: types=%s alias=%@",
                   NSStringFromClass(entity), types, NSStringFromSelector(alias));
        } else {
            ZARLog(@"STATE-SKIP setMessage: types=%s expected=v24@0:8@16",
                   types ?: "(null)");
        }
    }

    ZARScanStateMethodsForClass(entity);
    ZARInstallStateMutationTraceForClass(entity);
    ZARScanStateMethodsForClass(singleConversation);
    ZARInstallStateMutationTraceForClass(singleConversation);
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
