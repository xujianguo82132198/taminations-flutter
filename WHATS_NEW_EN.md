# What is New — Caller Features

## The name of this system: the Caller's Recording Studio

You record finished calling tracks (MP3) in this studio:
collect calls → detect the music beat → figures dance to it →
read each call as prompted → your recorder captures it →
repeat until satisfied. Every feature below is studio equipment.

## 1.6.116 (2026-10-17)

**Input area redesign (final)**
- Three-row initial screen: input box + X/Open/round buttons
  outside on the right (box narrowed; the keyboard slides up
  from the bottom and never covers the voice button);
  row 2 "Tap Calls to SELECT Call" (tap = selection);
  row 3 "Tap 📁 for VOICE INPUT" (display only)
- Rows 2-3 vanish when a table is opened, return at the
  initial screen
- X = clear the screen: text, draft and pipeline displays,
  keyboard kept (SOP: X before voice input, accumulate, Enter)

## 1.6.115 (2026-10-16)

**Base call is the first sub-call row (new)**
- Tap a call: the first row of the sub-call sheet is the bare
  call itself — e.g. "Square Thru" selects as-is (defaults to
  4 hands); append a number on the keyboard for Square Thru 6
- Library-wide verification: 518 base names are executable and
  go first; 118 concept/doc entries (e.g. "Alamo Style") are
  excluded automatically

**Fingerprint recording without interruptions (improved)**
- Every recording-time check removed (prefix-5, token
  collisions, duplicates within a call) — release the button
  and the fingerprint lands, nothing interrupts; duplicates
  are cleaned by "Sort & Save As"
- Keyboard pops up the moment you release the round button,
  so Enter is one tap away

**Directory rules finalized (improved)**
- Root level offers only Delete / Rename / Create Directory
  (selectable objects are directories; table actions absent)
- Inside a directory: table actions only (create/import/delete/
  rename/save-as/export/sort-save)
- Deleting or renaming a directory is done from the parent,
  never from inside; renaming moves all tables untouched,
  password included

## 1.6.114 (2026-10-15)

**Caller directories (new)**
- Type your name → Create Directory (no level question);
  enter it → two main actions: New Table, Import Table
- Both table kinds per level live side by side: Only tables
  (sorted by standard call) and token tables (sorted by
  fingerprint — used while calling)
- Mistaken empty directories can be deleted

**New Table (improved)**
- Inside a directory the name is pre-filled; choose level and
  table kind (Only / token)

**Import Table (new)**
- One button, two sources: phone file manager (.ysb) or
  another caller's directory (whole-table copy); imported
  tables land in the current directory

**Export / Import .ysb (new)**
- Exported filename is the bare table name (PSfix_Only.ysb)
- Location picking uses a built-in browser starting at storage
  root with a large "⬆ Up" button — no more getting stuck in
  Downloads; system folders show their names; a new folder
  can be created on the spot (Enter = create & enter)
- One-time "All files access" grant is prompted on first use

**Notices that wait for you (improved)**
- All results/errors are centered large-text dialogs dismissed
  by OK — never hidden or auto-vanishing

**Cleaner calls (fix)**
- Selection/Calls sub-call/PSfix lists strip the system-added
  "from" suffix and parenthetical notes — what you select
  always executes

**Selection appends (improved)**
- Calls picked on the Calls page append to the input box
  (prefix + call + suffix composition); X clears for a new one

## 1.6.113 (2026-10-14)

**Voice calling (new)**
- Hold the round button, speak, release: the recognized standard
  call lands in the input box; press Enter to execute
- Box turns yellow while listening; underline = still replaceable,
  disappears on release (confirmed)

**Three tricks for stubborn calls**
- Speak again with a firm initial consonant (sw-, sp-, ex-)
- Split into syllables: "Extend" → "ix · tend", "Dosado" → "do · sa · do"
- Or re-record the call in the Only table with your natural voice

**Table protection (new)**
- Opening/deleting/saving a table requires a password;
  the first password you enter becomes the permanent one

**Caller-tunable recognition (new)**
- Settings → Speech Recognition: noise suppression slider,
  prefix/suffix threshold, call-table threshold
  (right = strict, left = loose); settings are remembered

**Table management (new)**
- One-tap PSfix merge of prefix + suffix tables
- Merge any two tables (pick first → Merge → pick second → name)
- Only table: Add Row = add record (select/type the call);
  standard-call search (tap the yellow box, type a fragment)

**Music beat (new)**
- After beat detection, header / BPM / beat button flash in time
  with the music across a large screen area

**Misc**
- Three-line colored input guide on the first screen
- One-tap X to clear the input box
- Much faster recognition; many lag and freeze fixes
