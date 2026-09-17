#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Stores the last known message content/fields by messageId so recall handling
/// can operate after Zalo has already started mutating the ChatEntity.
void ZARRecallCacheEnsure(void);
void ZARRecallCacheSnapshot(id chatEntity);
nullable NSString *ZARRecallCachedMessage(id messageId);

NS_ASSUME_NONNULL_END
