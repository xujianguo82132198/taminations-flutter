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
5. **Table management UI**: per-caller directories (create /
   rename / delete from the parent level), Only tables and token
   tables per level, .ysb export/import through a built-in file
   browser (storage-root start, large Up button, on-the-spot
   folder creation), pure-union merge, standard-call search,
   password protection.
6. **Sub-call sheet**: first row is the bare call (verified
   executable library-wide; 118 concept entries excluded), so a
   picked call always dances; a keyboard number completes
   variants (Square Thru + 6).
7. **Docs**: USER_GUIDE_EN.md, WHATS_NEW_EN.md (plus Chinese
   counterparts).

## Where to look (main files)

| Area | File |
|------|------|
| Vosk bridge (audio feed, VAD, noise suppression, consonant boost, utterance-gap flush) | android/app/src/main/kotlin/.../MainActivity.kt |
| Dart speech provider (sessions, segmentation, n-best) | lib/sequencer/vosk_speech_to_text.dart |
| Voice state machine (press-to-talk input, table lookup, gates) | lib/sequencer/voice_flow.dart |
| Mapping-table engine (lookup, Power table, merge, drift report) | lib/sequencer/caller_store.dart |
| Sequencer UI (input row, dialogs, directories, beat flash, guide lines) | lib/sequencer/sequence_frame.dart |
| Built-in file browser (export/import, All-Files access) | lib/sequencer/phone_file_browser.dart |
| Calls selection page (levels, PSfix list, sub-call sheet) | lib/sequencer/sequencer_calls_page.dart |
| Settings block (noise/threshold sliders, attribution) | lib/pages/settings_page.dart |
| Beat-flashing bar | lib/pages/animation_page.dart |

Dependency added: `com.alphacephei:vosk-android:0.3.47` (Apache-2.0,
bundled model `vosk-model-en-us-0.22-lgraph`, ~40 MB, unpacked to
internal storage on first run). Attribution is shown in
Settings → Speech Recognition.

## Why we changed what we changed (original shortcomings addressed)

Taminations is an excellent *dancer's* app; these changes turn it
into a *caller's* workbench. Each addition answers a concrete gap:

| Original behavior | Shortfall for a working caller | Our change |
|---|---|---|
| Calls entered by keyboard / picking only | Elderly callers cannot type quickly at a dance | Offline push-to-talk voice input (hold button, speak, Enter) |
| One generic vocabulary for everyone | Elderly/accented voices misrecognized with no recourse | Caller-owned fingerprint tables ("many-to-one"): the system learns *your* pronunciation |
| (our own earlier builds used cloud ASR) | Quota, cost, network dependency, privacy | 100% offline Vosk; no cloud, free unlimited |
| Loose fuzzy matching on standard-call text | Wildly different sentences passed the gate ("the" matching "Trade") | Power weighting (position-based shape gate) + content-word floor; template = fingerprint only |
| Input row: plain hint text, no states | Caller cannot tell whether the system is listening; hint text overlapped buttons | Three colored guide lines, yellow box + underline = listening/replaceable, X to clear |
| Tables unprotected | Anyone could open/delete a caller's table | Password on open/delete/save-as (first entry sets it) |
| Figures dance at fixed speed presets | Practice with real music impossible | Beat detection from live music, figures + large-area screen flash follow the beat (MP3 calling-track workflow) |
| Settings page: inconsistent block formatting | Looked unfinished | Unified voice block, caller-tunable sliders with memory |
| System SAF picker starts in Downloads, no Up button on MIUI | Elderly callers got lost, saved into strangers' folders | Built-in file browser: starts at storage root, full-width Up button, named system folders, folder creation with Enter |
| Recording-time checks compared tokens against standard calls | Syllable fingerprints (ix·tend) were wrongly blocked | Prefix-5 baseline is the row's own token; duplicates left to cleanup — recording flows without interruptions |
| Sub-call lists contained raw animation titles | "…Gears from" rows selected but could not execute | Titles cleaned (from-suffix/parentheticals) and the bare call verified first row |

## Review suggestions

- The voice work is additive: without a caller table open, the app
  behaves as before; all voice UI lives behind the input row.
- Chinese comments mark user-driven decisions (design rationale);
  grep for 用户 ("user") to see them.
- Docs: USER_GUIDE_EN.md is the fastest tour of the feature set.

## License

GPLv3 unchanged (LICENSE file included). Vosk model and library
are Apache-2.0; attribution kept visible in Settings.
