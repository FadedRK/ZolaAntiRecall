#import <Foundation/Foundation.h>

/// Returns YES when the ChatEntity still carries text/media information.
BOOL ZARRecallHasRichContent(id chatEntity);

/// Whether this ChatEntity represents the current user's own recall.
BOOL ZARRecallIsMyRecall(id chatEntity);
