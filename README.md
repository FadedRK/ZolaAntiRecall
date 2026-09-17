# ZolaAntiRecall

Zalo iOS anti-recall research project for jailbroken/rootless Theos environments.

## Current architecture

```text
Tweak.xm
  ├─ Localization
  ├─ Settings
  └─ Diagnostics
       └─ Recall Interceptor
            ├─ Recall Cache
            └─ Recall Classifier
```

### Modules

- `Core/` — logging and shared runtime utilities.
- `Diagnostics/` — runtime target detection and diagnostic output only.
- `Recall/` — recall classification, message cache, and interception logic.
- `Settings/` — plugin settings and diagnostic screen.
- `Localization/` — zh / vi / en UI localization.
- `UI/` — legacy standalone menu injector; not currently part of the build target.

## Verified interception target under investigation

Current code probes:

- Class: `UndoChatProcessor`
- Selector: `updateUndoMessageContent:`
- Expected type encoding: `v24@0:8@16`

The interceptor replaces the verified IMP only after the class, selector, implementation and signature checks succeed.

## Recall flow

```text
Recall event
    ↓
UndoChatProcessor.updateUndoMessageContent:
    ↓
ZARRecallInterceptor
    ├─ master switch
    ├─ self/other recall classification
    ├─ original text / cached text lookup
    ├─ rich-content detection
    └─ ChatEntity.message replacement
          ↓
      original mutation is skipped
```

## Important limitation

The current cache is still populated from the available `ChatEntity` at recall handling time. The next research task is to hook an earlier normal-message lifecycle point so the original content is cached **before** Zalo starts recall mutation.

Do not treat the current hook as confirmed across all Zalo versions until it is verified on the target build/device.

## Build

The project uses Theos. `build_embed.py` generates `dylib/TranslationsData.m` from `Translations.plist` before building when translation data is present.

```bash
cd dylib
python3 build_embed.py
make package FINALPACKAGE=1
```

## Development order

1. Verify `UndoChatProcessor.updateUndoMessageContent:` on the target Zalo build.
2. Locate an earlier message-model lifecycle point for reliable pre-recall caching.
3. Verify plain-text recall.
4. Verify self-recall behavior.
5. Verify image/file/sticker/media behavior.
6. Regression-test master switch and fallback-to-original behavior.
