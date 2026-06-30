# Build Fix Notes

This revision fixes the GitHub Actions failure seen when the tweak was built inside the YTLitePlusEXTRA workflow.

Changes:

- Removed link-time dependency on `MediaToolbox.framework`.
- Resolved `MTAudioProcessingTapCreate`, `MTAudioProcessingTapGetSourceAudio`, and `MTAudioProcessingTapGetStorage` with `dlopen`/`dlsym` at runtime. This avoids failures when the SDK `.tbd` does not expose the tap symbols for every architecture.
- Kept the public `MTAudioProcessingTap` API and header path when the SDK provides it, with minimal fallback declarations for stripped SDKs.
- Preferred sibling `../YTVideoOverlay` headers when the repo is built inside the YTLitePlusEXTRA workflow, while keeping the vendored fallback for standalone builds.
- Removed unnecessary private framework linkage.

To use in the workflow that clones `https://github.com/Sohday67/test5silence.git`, replace that repository's contents with this zip and rerun the Action.
