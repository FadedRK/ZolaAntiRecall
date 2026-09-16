#import "ZARMessageTrace.h"
#import "../Core/ZARLogger.h"
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <substrate.h>

// Static VA in the analyzed Zalo Mach-O:
//   -[UndoChatProcessor updateUndoMessageContent:]
//   0x100A12400
// Therefore the image-relative offset is 0xA12400 when __TEXT starts at 0x100000000.
static const uintptr_t kZARUpdateUndoMessageContentOffset = 0xA12400;

static void (*ZAROrigUpdateUndoMessageContent)(id, SEL, id) = NULL;
static BOOL ZARDirectHookInstalled = NO;

static const struct mach_header_64 *ZARFindMainExecutableHeader(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        const char *lastSlash = strrchr(name, '/');
        const char *baseName = lastSlash ? lastSlash + 1 : name;
        if (strcmp(baseName, "Zalo") != 0) continue;

        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) return NULL;
        return (const struct mach_header_64 *)header;
    }
    return NULL;
}

static intptr_t ZARFindMainExecutableSlide(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        const char *lastSlash = strrchr(name, '/');
        const char *baseName = lastSlash ? lastSlash + 1 : name;
        if (strcmp(baseName, "Zalo") == 0) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }
    return 0;
}

static void ZARLogMainImageInfo(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        const char *lastSlash = strrchr(name, '/');
        const char *baseName = lastSlash ? lastSlash + 1 : name;
        if (strcmp(baseName, "Zalo") == 0) {
            const struct mach_header *header = _dyld_get_image_header(i);
            intptr_t slide = _dyld_get_image_vmaddr_slide(i);
            ZARLog(@"[ZAR-DIRECT-PROBE] Zalo image index=%u header=%p slide=0x%lx path=%s",
                   i, header, (unsigned long)slide, name);
            return;
        }
    }
    ZARLog(@"[ZAR-DIRECT-PROBE] Zalo main image not found");
}

static id ZARSafeValueForKey(id obj, NSString *key) {
    if (!obj || ![obj respondsToSelector:NSSelectorFromString(key)]) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *exception) {
        ZARLog(@"[ZAR-DIRECT-PROBE] KVC exception key=%@", key);
        return nil;
    }
}

static NSString *ZARSafeDescription(id obj) {
    if (!obj) return @"(nil)";
    @try {
        NSString *desc = [obj description];
        if (![desc isKindOfClass:[NSString class]]) return @"<non-string description>";
        return desc.length > 500 ? [desc substringToIndex:500] : desc;
    } @catch (__unused NSException *exception) {
        return @"<description threw exception>";
    }
}

static void ZARHookUpdateUndoMessageContent(id self, SEL _cmd, id arg) {
    @autoreleasepool {
        ZARLog(@"[ZAR-DIRECT-PROBE] === updateUndoMessageContent TRIGGERED ===");
        ZARLog(@"[ZAR-DIRECT-PROBE] self=%p class=%@ arg=%p",
               self,
               self ? NSStringFromClass(object_getClass(self)) : @"(nil)",
               arg);

        if (arg) {
            Class argClass = object_getClass(arg);
            ZARLog(@"[ZAR-DIRECT-PROBE] Arg Class: %@", argClass ? NSStringFromClass(argClass) : @"(nil)");
            ZARLog(@"[ZAR-DIRECT-PROBE] Arg Superclass: %@",
                   argClass && class_getSuperclass(argClass)
                       ? NSStringFromClass(class_getSuperclass(argClass))
                       : @"(nil)");
            ZARLog(@"[ZAR-DIRECT-PROBE] Arg Desc: %@", ZARSafeDescription(arg));

            id value = ZARSafeValueForKey(arg, @"messageId");
            if (value) ZARLog(@"[ZAR-DIRECT-PROBE] messageId: %@", value);

            value = ZARSafeValueForKey(arg, @"message");
            if (value) ZARLog(@"[ZAR-DIRECT-PROBE] message: %@", value);

            value = ZARSafeValueForKey(arg, @"status");
            if (value) ZARLog(@"[ZAR-DIRECT-PROBE] status: %@", value);

            value = ZARSafeValueForKey(arg, @"isRecallDelByMySelf");
            if (value) ZARLog(@"[ZAR-DIRECT-PROBE] isRecallDelByMySelf: %@", value);

            if ([arg isKindOfClass:[NSNotification class]]) {
                NSNotification *notification = (NSNotification *)arg;
                ZARLog(@"[ZAR-DIRECT-PROBE] Notif Name: %@", notification.name);
                ZARLog(@"[ZAR-DIRECT-PROBE] Notif UserInfo: %@", notification.userInfo ?: @{});
            }
        } else {
            ZARLog(@"[ZAR-DIRECT-PROBE] arg=nil");
        }

        ZARLog(@"[ZAR-DIRECT-PROBE] ========================================");
    }

    // Pure pass-through: the original implementation is always called.
    if (ZAROrigUpdateUndoMessageContent) {
        ZAROrigUpdateUndoMessageContent(self, _cmd, arg);
    } else {
        ZARLog(@"[ZAR-DIRECT-PROBE] ERROR: original function pointer is nil");
    }
}

static void ZARInstallDirectProbe(void) {
    if (ZARDirectHookInstalled) return;

    const struct mach_header_64 *header = ZARFindMainExecutableHeader();
    if (!header) {
        ZARLog(@"[ZAR-DIRECT-PROBE] Abort: Zalo main Mach-O not found");
        return;
    }

    intptr_t slide = ZARFindMainExecutableSlide();
    if (slide == 0) {
        ZARLog(@"[ZAR-DIRECT-PROBE] Abort: could not obtain Zalo ASLR slide");
        return;
    }

    uintptr_t base = (uintptr_t)header;
    uintptr_t target = base + kZARUpdateUndoMessageContentOffset;

    ZARLog(@"[ZAR-DIRECT-PROBE] base=0x%lx slide=0x%lx offset=0x%lx target=0x%lx",
           (unsigned long)base,
           (unsigned long)slide,
           (unsigned long)kZARUpdateUndoMessageContentOffset,
           (unsigned long)target);

    // Avoid an Objective-C runtime lookup entirely. The address is derived from
    // the analyzed Zalo executable's image-relative offset.
    MSHookFunction((void *)target,
                   (void *)ZARHookUpdateUndoMessageContent,
                   (void **)&ZAROrigUpdateUndoMessageContent);

    if (!ZAROrigUpdateUndoMessageContent) {
        ZARLog(@"[ZAR-DIRECT-PROBE] ERROR: MSHookFunction did not return original IMP");
        return;
    }

    ZARDirectHookInstalled = YES;
    ZARLog(@"[ZAR-DIRECT-PROBE] HOOK INSTALLED target=0x%lx original=%p",
           (unsigned long)target,
           ZAROrigUpdateUndoMessageContent);
}

void ZARRunMessageTrace(void) {
    ZARLog(@"===== ZolaAntiRecall direct memory parameter probe =====");
    ZARLog(@"Process=%@ PID=%d", NSProcessInfo.processInfo.processName, NSProcessInfo.processInfo.processIdentifier);
    ZARLogMainImageInfo();

    // Do not depend on Objective-C class registration timing.
    ZARInstallDirectProbe();

    // Diagnostic only: verify whether the class becomes visible later.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(@"UndoChatProcessor");
        ZARLog(@"[ZAR-DIRECT-PROBE] delayed 5s NSClassFromString(UndoChatProcessor)=%@",
               cls ? @"FOUND" : @"NOT FOUND");
    });
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
