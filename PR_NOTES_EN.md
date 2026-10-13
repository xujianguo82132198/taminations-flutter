# Modification Summary for Upstream (Taminations Flutter)

This fork adds an **offline voice-calling workbench** for square
dance callers on top of Taminations, plus documentation in both
Chinese and English. Everything remains GPLv3.

## What the caller gets

1. **Voice input**: hold a round button, speak, release — the
   recognized standard call lands in the input box; Enter executes.
   Recognition is fully offline (Vosk), free, no cloud.
2. **Caller-owned mapping tables**: each caller keeps tables of
   fingerprints (recognized wordings) mapped to standard calls
   ("many-to-one"). The lookup compares against fingerprints only;
   the standard-call column is just the query result.
3. **Power weighting**: a 33×33 position-weight table (front-loaded,
   row sum = 1) gates matches by word shape; caller-tunable
   thresholds in Settings.
4. **Music beat sync**: beat detection drives the dancing figures
   and large-area screen flashing, aimed at producing MP3 calling
   tracks (play sequence + read prompts + external recorder).
5. **Table management UI**: create/import/merge tables (pure-union
   merge), PSfix one-tap merge, standard-call search, password
   protection, per-caller directories.
6. **Docs**: USER_GUIDE_EN.md, WHATS_NEW_EN.md (plus Chinese
   counterparts).

## Where to look (main files)

| Area | File |
|------|------|
| Vosk bridge (audio feed, VAD, noise suppression, consonant boost, utterance-gap flush) | android/app/src/main/kotlin/.../MainActivity.kt |
| Dart speech provider (sessions, segmentation, n-best) | lib/sequencer/vosk_speech_to_text.dart |
| Voice state machine (press-to-talk input, table lookup, gates) | lib/sequencer/voice_flow.dart |
| Mapping-table engine (lookup, Power table, merge, drift report) | lib/sequencer/caller_store.dart |
| Sequencer UI (input row, dialogs, beat flash, guide lines) | lib/sequencer/sequence_frame.dart |
| Settings block (noise/threshold sliders, attribution) | lib/pages/settings_page.dart |
| Beat-flashing bar | lib/pages/animation_page.dart |

Dependency added: `com.alphacephei:vosk-android:0.3.47` (Apache-2.0,
bundled model `vosk-model-en-us-0.22-lgraph`, ~40 MB, unpacked to
internal storage on first run). Attribution is shown in
Settings → Speech Recognition.

## Review suggestions

- The voice work is additive: without a caller table open, the app
  behaves as before; all voice UI lives behind the input row.
- Chinese comments mark user-driven decisions (design rationale);
  grep for 用户 ("user") to see them.
- Docs: USER_GUIDE_EN.md is the fastest tour of the feature set.

## License

GPLv3 unchanged (LICENSE file included). Vosk model and library
are Apache-2.0; attribution kept visible in Settings.
