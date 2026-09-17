#import "ZARMessageTrace.h"
#import "../Core/ZARLogger.h"
#import "../Recall/ZARRecallCache.h"
#import "../Recall/ZARRecallInterceptor.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static void ZARScanRecallTarget(void) {
    Class cls = objc_getClass("UndoChatProcessor");
    if (!cls) {
        ZARLog(@"[ZAR-DIAG] UndoChatProcessor NOT FOUND");
        return;
    }
    SEL selector = NSSelectorFromString(@"updateUndoMessageContent:");
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) method = class_getClassMethod(cls, selector);
    if (!method) {
        ZARLog(@"[ZAR-DIAG] UndoChatProcessor exists, updateUndoMessageContent: NOT FOUND");
        return;
    }
    const char *types = method_getTypeEncoding(method);
    ZARLog(@"[ZAR-DIAG] Recall target found: %@ / %@ / types=%s / IMP=%p",
           NSStringFromClass(cls), NSStringFromSelector(selector), types ?: "(null)", method_getImplementation(method));
}

void ZARRunMessageTrace(void) {
    ZARLog(@"===== ZolaAntiRecall RECALL DIAGNOSTICS =====");
    ZARLog(@"Process=%@ PID=%d", NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier);
    ZARScanRecallTarget();
    ZARRecallCacheEnsure();
    ZARInstallRecallInterceptor();
}

NSString *ZARDiagnosticText(void) {
    NSString *text = [NSString stringWithContentsOfFile:ZARLogPath() encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return @"暂无探测日志。请点击“重新扫描”。";
    if (text.length > 30000) text = [text substringFromIndex:text.length - 30000];
    return text;
}

void ZARInstallMessageTrace(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ZARRunMessageTrace();
        });
    });
}
