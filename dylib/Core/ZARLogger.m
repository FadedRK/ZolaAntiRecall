#import "ZARLogger.h"
#include <stdarg.h>

NSString *ZARLogPath(void) {
    NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
    return [documents stringByAppendingPathComponent:@"ZolaAntiRecall.log"];
}

void ZARLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[ZolaAntiRecall] %@", message);
    NSString *old = [NSString stringWithContentsOfFile:ZARLogPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *line = [old stringByAppendingFormat:@"%@\n", message];
    [line writeToFile:ZARLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
