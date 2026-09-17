# Test Plan

## Device baseline

Record before each test:

- iOS version
- Zalo version/build
- jailbreak/rootless environment
- tweak build commit

## Cases

| ID | Case | Expected |
|---|---|---|
| R01 | Receive normal text | Message remains unchanged |
| R02 | Other person recalls text | Original text remains in ChatEntity with recall tag |
| R03 | Self recall, switch ON | Original text remains with self-recall tag |
| R04 | Self recall, switch OFF | Native Zalo recall behavior |
| R05 | Recall with empty `message` but cached text | Cached text is restored |
| R06 | Image/file/sticker recall | Media fields are not intentionally destroyed by interceptor |
| R07 | Master switch OFF | Native Zalo behavior |
| R08 | Target class/selector missing | No crash; diagnostic log records failure |
| R09 | Unexpected method signature | Hook is not installed |
| R10 | Repeated launch | Hook is installed at most once |

## Required logs

For a successful interception capture:

- target class
- selector
- method type encoding
- original IMP
- messageId
- self/other recall classification
- rich-content classification
- replacement result
- whether original implementation was blocked

## Pass criteria

A test is not considered confirmed only because the UI looks correct. The runtime log must show the expected hook and model mutation path.
