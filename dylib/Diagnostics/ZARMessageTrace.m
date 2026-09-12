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

void ZARInstallMessageTrace(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ZARLog(@"===== ZolaAntiRecall runtime discovery =====");
        for (NSString *name in ZARKeywords()) {
            ZARScanSelector(NSSelectorFromString(name));
        }
        ZARLog(@"TRACE ONLY: no method implementations changed");
    });
}
