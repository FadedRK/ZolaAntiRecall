#import "ZARRecallCache.h"
#import "../Core/ZARLogger.h"
#import <objc/runtime.h>
#import <os/lock.h>

static NSMutableDictionary *ZARMessageCache;
static os_unfair_lock ZARMessageCacheLock = OS_UNFAIR_LOCK_INIT;

static id ZARSafeGet(id object, NSString *key) {
    if (!object || !key) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static NSString *ZARString(id value) {
    if (!value || value == [NSNull null]) return nil;
    if ([value isKindOfClass:NSString.class]) return value;
    @try {
        if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSString *ZARKey(id messageId) {
    NSString *s = ZARString(messageId);
    if (s.length) return [NSString stringWithFormat:@"s:%@", s];
    if (!messageId) return nil;
    return [NSString stringWithFormat:@"o:%@", messageId];
}

void ZARRecallCacheEnsure(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ ZARMessageCache = [NSMutableDictionary dictionary]; });
}

void ZARRecallCacheSnapshot(id chatEntity) {
    ZARRecallCacheEnsure();
    id messageId = ZARSafeGet(chatEntity, @"messageId");
    NSString *key = ZARKey(messageId);
    if (!key) return;

    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    NSString *message = ZARString(ZARSafeGet(chatEntity, @"message"));
    if (message.length) snapshot[@"message"] = [message copy];

    for (NSString *field in @[@"mediaId", @"richMsgNormal", @"msgExtraData", @"paramExt", @"property", @"mediatype", @"originTextRecallMsg"]) {
        id value = ZARSafeGet(chatEntity, field);
        if (!value || value == [NSNull null]) continue;
        id safeValue = value;
        @try {
            if ([value conformsToProtocol:@protocol(NSCopying)]) safeValue = [value copy];
        } @catch (__unused NSException *e) {}
        if (safeValue) snapshot[field] = safeValue;
    }

    if (!snapshot.count) return;
    os_unfair_lock_lock(&ZARMessageCacheLock);
    ZARMessageCache[key] = snapshot;
    // Bound memory while keeping enough recent messages for recall testing.
    if (ZARMessageCache.count > 500) {
        NSString *firstKey = ZARMessageCache.allKeys.firstObject;
        if (firstKey) [ZARMessageCache removeObjectForKey:firstKey];
    }
    os_unfair_lock_unlock(&ZARMessageCacheLock);
    ZARLog(@"[ZAR-CACHE] snapshot key=%@ fields=%@", key, snapshot.allKeys);
}

NSString *ZARRecallCachedMessage(id messageId) {
    ZARRecallCacheEnsure();
    NSString *key = ZARKey(messageId);
    if (!key) return nil;
    os_unfair_lock_lock(&ZARMessageCacheLock);
    NSDictionary *snapshot = [ZARMessageCache[key] copy];
    os_unfair_lock_unlock(&ZARMessageCacheLock);
    return ZARString(snapshot[@"message"]);
}
