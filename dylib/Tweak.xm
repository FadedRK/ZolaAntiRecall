#import <Foundation/Foundation.h>
#import "Core/ZARLogger.h"
#import "Diagnostics/ZARMessageTrace.h"
#import "Settings/ZARSettings.h"
#import "Localization/ZARLocalization.h"

__attribute__((constructor))
static void ZARInit(void) {
    @autoreleasepool {
        ZARLog(@"ZolaAntiRecall loaded; initializing modules");
        ZARInstallLocalization();
        ZARInstallMessageTrace();
        ZARInstallSettings();
    }
}
