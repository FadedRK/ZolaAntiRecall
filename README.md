# ZolaAntiRecall

Zalo iOS anti-recall research project.

## Goal
Locate the real recall notification / message-model mutation path and eventually prevent the original recall operation from mutating the local message model.

## Principles
- No UI-level anti-recall as the core solution.
- No speculative hook is treated as confirmed.
- Trace first, then hook the earliest verified data/notification handler.
- Keep diagnostics separate from blocking logic.
- One test device is available, so every build must be self-diagnosing.

## Current evidence
Known Zalo runtime candidates include:
- handleRecallMessageNotification:
- _handleRecallWithData:
- onActionRecallMessages:
- processAfterRecallMessageSuccess:
- proccessUndoInMediaStoreWithMessageId:isGroup:isOwnerRecall:
- updateDBWhenRecalledChats:completion:
- set_recallTime:
- setRecallTime:
- recall:

Runtime traces have shown MSDataCoordinator, MSLocalCache, ConversationModel, and ChatEntity around recall handling.

The current investigation target is the message/data layer, not UILabel/UI rendering.
