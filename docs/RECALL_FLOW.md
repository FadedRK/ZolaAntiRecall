# Recall Flow

## Current path

The current implementation treats `UndoChatProcessor.updateUndoMessageContent:` as the interception point under investigation.

```text
Zalo recall event
      ↓
UndoChatProcessor
      ↓
updateUndoMessageContent:
      ↓
ZARRecallInterceptor
      ├── master switch
      ├── self/other recall
      ├── text lookup
      ├── rich-content check
      └── set ChatEntity.message
```

## Cache

`ZARRecallCache` stores snapshots by `messageId` and is bounded to 500 entries. It currently records `message` plus selected media/model fields when a `ChatEntity` snapshot is available.

This is intentionally separated from the interceptor so the cache can later be fed by an earlier message lifecycle hook.

## Next target

Find a normal message creation/update path that exposes the original `ChatEntity` before recall mutation. The desired flow is:

```text
normal message update
      ↓
ZARRecallCacheSnapshot
      ↓
messageId → original content
      ↓
recall
      ↓
interceptor reads cache
```

Only promote a candidate to a production hook after runtime evidence confirms its timing and arguments.
