#import <Foundation/Foundation.h>
#import "Core/ZARLogger.h"
#import "Diagnostics/ZARMessageTrace.h"
#import "UI/ZARPluginMenu.h"

__attribute__((constructor))
static void ZARInit(void) {
    @autoreleasepool {
        ZARLog(@"ZolaAntiRecall loaded; TRACE ONLY; no recall blocking");
        ZARInstallMessageTrace();
        ZARInstallPluginMenuHook();
    }
}
