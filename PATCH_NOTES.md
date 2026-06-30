# Patch notes

## v3 build fix

The third GitHub Actions run reached `Sources/YTSSSilenceController.m` and then failed before the `YTSkipSilence.dylib` target completed. The source contained one invalid AVFoundation key:

- Incorrect: `AVLinearPCMIsNonInterleaved`
- Correct: `AVLinearPCMIsNonInterleavedKey`

This has been fixed in v3.

Additional guardrails:

- Added permissive warning flags for private/optional Objective-C selectors so Actions does not fail on SDK warning churn.
- Kept the v2 AVFoundation-only analysis path. No MediaToolbox / `MTAudioProcessingTap` symbols are linked.
- Kept the YTVideoOverlay button registration pattern with sibling-header preference and vendored fallback headers.

If another failure appears, rerun with:

```sh
make clean package DEBUG=1 messages=yes THEOS_PACKAGE_SCHEME=rootless
```

That will force Theos to print the exact compiler/linker command and diagnostic line.
