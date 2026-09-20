# Pickroom for iOS — Execution Plan

Companion to [zjywill/Pickroom](https://github.com/zjywill/Pickroom) (macOS) and
to its Auto Group design, [Pickroom#1](https://github.com/zjywill/Pickroom/issues/1).
That issue holds the algorithm design — grouping kinds, the time-first
similarity rule, best-shot ranking — and is **not repeated here**. This document
covers what is specific to iOS: what changes, what gets dropped, how the
interaction differs, and the phase-by-phase plan with verification.

---

## 1. Why an iOS app exists

The macOS app can only free space on a phone *indirectly*. Deleting a photo on
the Mac frees the phone only if iCloud Photos is on, and even then the phone was
probably holding an optimised rendition, so the bytes returned to the device are
a fraction of what the Mac reported. If iCloud Photos is off, culling on the Mac
does nothing at all for the phone.

On iOS the app acts on the device library directly, and it can read the device's
real free space before and after (`URLResourceKey.volumeAvailableCapacityForImportantUsageKey`,
iOS 11+). **The storage problem lives on the phone, and so should the tool.**

The second reason is the shape of the session. Mac culling is an hour at a desk.
Phone culling is three minutes in a queue, one-handed, interrupted. Every design
decision below follows from that difference.

### Positioning

Pickroom is a tool for choosing your best photographs. That does not change on
iOS. Storage pressure is *why* someone opens the app; picking keepers is *what*
they do in it; reclaimed gigabytes are the proof it worked.

Grouping and best shot are **triage that accelerates the user's own decision**,
never a decision made for them. On a phone that acceleration is the entire
product: without it, a fifty-thousand-photo library is not reviewable at all on
a 6-inch screen.

---

## 2. Scope relative to macOS

### Dropped entirely

| Mac capability | Why it goes |
|---|---|
| `RawEngine` / LibRaw | An iPhone does not shoot third-party RAW. ProRAW is DNG and ImageIO decodes it natively. This also removes the CDDL/LGPL licensing story, `Tools/build-libraw.sh`, the vendored framework, and its share of the release pipeline. |
| Folder source, `FolderAccess`, security-scoped bookmarks | Nothing on iOS lives outside the Photos library. |
| `RejectArchive` (moving files to a folder) | There is no user-visible filesystem. Rejection resolves to PhotoKit deletion instead. |
| `LocationSidecar`, `PhotoLocationWriter`, `LocationPickerView` | iPhone photos already carry GPS. Writing locations onto files has no iOS equivalent and no demand. |
| `SVGSupport` | Not a photo-library format. |
| Keyboard shortcuts (`CullingShortcuts`) | Replaced by gestures. Hardware-keyboard support on iPad can come back later. |
| Full-resolution zoom / focus inspection | Deliberately deferred. It is a desk activity. |

### Carried over as concepts, reimplemented

| Concept | iOS form |
|---|---|
| `PhotoDecision` (unreviewed / pick / maybe / reject) | Same four states, same semantics. |
| `SelectionStore` | Same idea, keyed by `PHAsset.localIdentifier`. |
| `PreviewPipeline` | Replaced by `PHCachingImageManager` with a sliding prefetch window. |
| Group engine, best-shot ranking | **Same algorithms**, see §7. |
| `AssetSource` | Collapses to a single case. Keep the type anyway so core code stays platform-neutral. |

### New on iOS

- Real device free space, before and after.
- Batch deletion through one system confirmation.
- Limited-library access as a first-class state.
- Thermal and Low Power Mode throttling.
- Background fingerprinting while charging.
- Resume-exactly-where-you-were session state.

---

## 3. The honest storage picture

This has to be built in from the first screen, not bolted on. Getting it wrong
means promising space the app cannot deliver.

### iCloud configuration changes the arithmetic

| Setting | Deleting one photo frees |
|---|---|
| iCloud Photos **off** | Full original size, on this device. 1:1, the simple case. |
| iCloud Photos on, **Download and Keep Originals** | Full original size on device **and** in iCloud. 1:1. |
| iCloud Photos on, **Optimise iPhone Storage** | Full size in iCloud, but only the optimised rendition on the device — often 10–20% of the original. |

The app must detect which case applies and **show two numbers wherever it shows
one today**: "frees 4.2 GB in iCloud · 0.8 GB on this iPhone". Local availability
is detectable per asset without touching the network, by requesting image data
with `isNetworkAccessAllowed = false` and observing
`PHImageResultIsInCloudKey`, or via `PHAssetResource` availability.

### The one-tap win the app should simply tell the user about

If the device is full, iCloud Photos is on, and *Optimise iPhone Storage* is
**off**, then turning it on will free more space in one tap than an hour of
culling. The app should say so plainly on the first screen and link to Settings.

Giving away a chunk of its own value proposition in the first thirty seconds is
the right call: it is true, it is what a knowledgeable friend would say, and an
app that opens by being honest earns the permission to ask for a deletion later.

### Recently Deleted

Deleted assets sit in Recently Deleted for 30 days and **the space is not
returned until it is emptied**. The app must:

- show a live "pending in Recently Deleted: X GB" figure, and
- link to the Photos app to empty it.

It must **never** empty it automatically. That is the one irreversible step and
it belongs to the user.

### Video

`PHAsset` video is where most of the bytes are on a phone — one minute of 4K60
is roughly 400 MB, about 130 HEIC stills. The Mac app currently filters to
`mediaType == image`. **On iOS, excluding video would mean ignoring the majority
of the problem on the device where the problem is worst.**

Proposal, same as the Mac issue: include video for **accounting and
largest-items** from Phase 0 — poster frame, duration, size — with no playback,
scrubbing or frame review. Swipe triage over video can come later or never.

### Live Photos

Each carries a ~3 second movie, typically 2–3× a plain still. Count them at true
total size across all resources. PhotoKit cannot strip the movie in place, so
the only lever is deleting the asset; showing the real size at least makes the
choice informed.

---

## 4. The core interaction: group-aware swipe triage

This is the part of the app that has no Mac equivalent, and it is the reason the
iOS app is worth building.

### The deck

One card at a time, full screen, thumb-driven:

- **Swipe right** — keep. (`pick`)
- **Swipe left** — discard. (`reject`)
- **Swipe up** — maybe, decide later. (`maybe`)
- **Tap** — inspect larger, pinch to zoom.
- **Long press** — see the whole group.

Haptics on every commit. No confirmation dialogs during triage — the entire
value is rhythm, and a dialog every few seconds destroys it. Safety comes from
undo and from the fact that nothing leaves the library until an explicit commit.

### One gesture resolves a whole group

The deck does not serve loose photos. It serves **groups**, and this is the
central idea:

```
┌─────────────────────────┐
│                         │
│      best shot          │   Burst · 14 photos · 380 MB
│      ★ sharpest         │
│                         │   ← discard 13, keep this one
│   ▫ ▫ ▪ ▫ ▫ ▫  +8       │   → keep all 14
└─────────────────────────┘   ↑ decide later
```

A burst of 14 is one card, not 14. Swiping right keeps the suggested best shot
and discards the other 13 in a single gesture. Swiping left discards all 14.
The strip of thumbnails underneath is tappable to change which frame is the
keeper before deciding.

**This is where the fifty-thousand-photo library becomes tractable.** A few
hundred cards stand in for tens of thousands of photos, and the highest-yield
cards come first because groups are ordered by reclaimable bytes.

Groups whose default is *keep all* — bracketed exposures, original-plus-edit
pairs — appear as a single collapsed card that is swiped past, not as a deletion
prompt. Proposing that someone delete their HDR source frames is how an app of
this kind loses a user permanently.

### Undo

A persistent, thumb-reachable undo button, plus shake-to-undo. Undo must step
back through whole cards, so undoing a group restores all of its members at
once. Undo depth of at least 20.

### Commit

Decisions accumulate locally. Nothing is deleted during triage. When the user
chooses to commit:

1. A review sheet: a grid of everything about to go, the total size, and the two
   storage numbers from §3.
2. One `PHPhotoLibrary.performChanges` with `PHAssetChangeRequest.deleteAssets`
   for the whole batch.
3. **iOS shows its own system confirmation** — one alert for the entire batch,
   not one per photo. This is a meaningful advantage over doing it photo by
   photo and the batching should be designed around it.
4. Assets land in Recently Deleted; the "pending" figure updates; the user is
   told what remains to be done in the Photos app.

### Session shape

Phone culling is interrupted by definition. Therefore:

- Every decision persists immediately. Killing the app loses nothing.
- Reopening returns to the exact card.
- A session summary on return: "Last time: 412 photos reviewed, 6.1 GB marked."
- Progress is expressed against a goal the user sets ("free 20 GB"), because a
  finishable task gets finished and an endless one gets abandoned.

---

## 5. Access, permissions, privacy

- Request `.readWrite`. Deletion needs it, and asking later mid-flow is worse
  than asking up front with an explanation.
- **`.limited` is a first-class state on iOS**, far more common than on macOS.
  The app must work correctly over a limited selection and offer
  `presentLimitedLibraryPicker(from:)` rather than nagging. Set
  `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` so the system's own prompt
  does not fire on every launch.
- All analysis is on-device. No network, ever, for grouping or scoring — the
  macOS `allowsNetworkAccess: false` contract carries over verbatim. Say this in
  the UI; "automatically analyse my photos" is an alarming sentence without it.
- No analytics on photo content. If any telemetry exists at all, it is counts
  and timings, opt-in.

---

## 6. Architecture

```
Pickroom-iOS/
├── Packages/
│   └── PickroomCore/          # SPM, platform-neutral, no UIKit/AppKit
│       ├── Models/            # PhotoDecision, PhotoGroup, ShotScore
│       ├── Grouping/          # GroupEngine: time clustering, kinds, thresholds
│       ├── Ranking/           # ShotRanker protocol + scorers
│       └── Fingerprint/       # dHash, candidate selection
└── Pickroom/
    ├── App/
    ├── Library/               # PhotoKitLibrary, AssetSizer, ImageCache
    ├── Triage/                # the deck, gestures, undo, commit
    ├── Storage/               # free space, iCloud state, Recently Deleted
    └── Review/                # grid, filters, per-group detail
```

`PickroomCore` imports nothing but Foundation. The grouping and ranking logic is
identical to the Mac app's, so writing it platform-neutral from day one keeps
the option of extracting it into a shared package later. **Do not set up a
cross-repo dependency now** — duplicate logic is cheaper than coupling two
unshipped codebases. Revisit once both have shipped once.

### Technical choices

| Decision | Choice | Rationale |
|---|---|---|
| Minimum iOS | **18.0** | Gives `VNCalculateImageAestheticsScoresRequest` unconditionally (iOS 18+), so no availability gating. iOS 27 is current; 18 is a wide net. |
| UI | SwiftUI, UIKit where gestures demand it | The card deck may need a `UIPanGestureRecognizer` for interruptible, velocity-accurate drags. Do not fight SwiftUI on this. |
| Concurrency | Swift 6 strict | New codebase, no migration cost. |
| Project generation | XcodeGen (`project.yml`) | Matches the Mac repo's convention. |
| Images | `PHCachingImageManager` | Mandatory at this scale; a sliding window around the deck position. |
| Persistence | SQLite or a compact binary table | Tens of thousands of rows for decisions, sizes, fingerprints and scores. JSON will not hold. |

### Device constraints that do not exist on Mac

- **Memory.** Far tighter. The image cache must be sized from
  `ProcessInfo.physicalMemory` and must drop under memory pressure.
- **Thermals.** Pause Stage B fingerprinting when `ProcessInfo.thermalState` is
  `.serious` or worse, and when Low Power Mode is on. A culling app that heats
  the phone gets deleted.
- **Background.** Fingerprint via `BGProcessingTask` with
  `requiresExternalPower = true`. The ideal is that the work happens overnight on
  the charger and the user never watches a progress bar.

---

## 7. Algorithms — deltas only

The full design is in [Pickroom#1](https://github.com/zjywill/Pickroom/issues/1).
What changes on iOS:

**Time-first similarity is unchanged and non-negotiable.** Visual similarity is
only computed inside a capture session; a selfie from this year and one from
next year are never grouped however alike they look. The floating threshold table
carries over as-is.

**Byte accounting is the same problem** — `PHAsset` exposes no public file size.
Same three options, same recommendation: estimate from dimensions for instant
whole-library ranking, resolve exact sizes lazily for what is on screen, cache
both, keep the exact-size lookup behind one swappable method. iOS adds the
local-versus-iCloud split from §3.

**Best shot gets easier.** `PHAsset.burstSelectionTypes` (`.userPick` >
`.autoPick`) is more often populated on a device library than on a Mac's, and it
is free. Beyond that the ladder is unchanged: face capture quality, then
aesthetics, then the sharpness/exposure fallback — with the two rules that decide
whether it feels smart or broken: measure sharpness on the **subject** region,
not the whole frame, and normalise scores **within the group**.

**Scoring budget is tighter.** Score only the cards near the current deck
position, on a ~512 px rendition, and cache. The Neural Engine makes face
quality fast, but battery is the real budget, not milliseconds.

**RAW handling collapses.** ProRAW DNGs are decoded by ImageIO like anything
else. The only RAW-related behaviour worth keeping is that a ProRAW asset is
large, so it matters for byte ranking.

---

## 8. Phases

Each phase ships something usable on its own.

### Phase 0 — Skeleton, access, and the storage picture

Project scaffolding, XcodeGen, permission flow including `.limited`, device free
space, iCloud configuration detection, per-asset size estimation with the exact
lookup behind a protocol, video included for accounting.

Ships as a single screen that answers "what is eating my storage" with a
size-sorted list, the two storage numbers, the Recently Deleted figure, and the
Optimise-Storage advice from §3. **No triage, no grouping — and still worth
installing.**

### Phase 1 — The deck, over a flat stream

The card, the four gestures, haptics, undo, decision persistence, session
resume, `PHCachingImageManager` prefetch, the commit sheet and batch delete.

Ships as a genuinely fast culler over recent photos. This is the phase that
proves the interaction; everything after it multiplies its throughput.

### Phase 2 — Grouping, and the group-aware card

`PickroomCore` grouping Stage A: time clustering, `burstIdentifier`,
`mediaSubtypes`, bracket and version guards, screenshot and saved detection,
size ranking. The deck starts serving groups instead of photos. Groups ordered
by reclaimable bytes. Permanent per-group dismissal.

This is where the throughput jump happens — the multiplier on Phase 1.

### Phase 3 — Best shot

`ShotRanker`: `burstSelectionTypes` short circuit, then the fallback scorer
(saliency-cropped sharpness and exposure), then face capture quality, then
aesthetics. Visible reason on every suggestion, one-tap override that persists.

### Phase 4 — Near duplicates

dHash behind a protocol, candidates drawn only from Stage A's time-adjacent
sets, the floating threshold table, on-disk fingerprint cache keyed by
`localIdentifier` + modification date, `BGProcessingTask` scheduling with
thermal and power throttling.

### Phase 5 — Review and parity

Grid review, decision filters, per-group detail, a proper picks view, the
reclaimed-bytes report after Recently Deleted is emptied, iPad layout, hardware
keyboard support.

---

## 9. Verification

### What the Simulator cannot test

State this plainly up front, because it shapes the whole test strategy. The iOS
Simulator has a small synthetic photo library and **cannot** exercise: real
device free space, iCloud Photos configuration, Optimise Storage renditions,
`PHImageResultIsInCloudKey`, thermal state, Low Power Mode, background task
scheduling, or realistic library scale.

**Everything in §3 and every performance claim must be verified on a real
device.** The Simulator covers correctness of pure logic and UI layout, nothing
more.

### Automated — `PickroomCore`, no library access

Pure functions, fast, run in CI:

- **The cross-year case:** two assets with identical fingerprints 365 days apart
  produce **no** near-duplicate group. Write this test first; the entire
  time-first design exists for it.
- Time clustering: gap exactly at threshold; a session crossing midnight stays
  one session; a timezone jump does not split it; degenerate all-zero timestamps
  fall back to ordering by identifier.
- Floating threshold: the same fingerprint distance groups at 2 s and does not
  at 2 h.
- Bracket guard: three frames at exposure bias −2/0/+2 within one second are
  `bracket` with a keep-all default, never `nearDuplicate`.
- Versions guard: an original and its edited counterpart never form a deletion
  prompt.
- Byte accounting: an asset's size sums **all** its resources, including the
  Live Photo movie; already-deleted assets contribute zero.
- Group identity: the same members in a different order produce the same group
  id, and group state survives a rescan.
- Ranking: a synthetic group of one sharp and two blurred frames ranks the sharp
  one first; a tie inside 5% returns two candidates rather than one.

### Automated — app layer, Simulator

- Permission states render correctly: not determined, denied, `.limited`,
  authorised.
- Over a `.limited` selection the app groups and triages only the selected
  assets and offers the limited-library picker.
- Deck gestures produce the expected decisions; undo restores a whole group in
  one step; decisions survive a process kill and relaunch.
- The commit sheet totals match the sum of pending rejects.

### Manual — real device, required before any release

Use a **test device or a throwaway library**. Deletion is real.

1. **Access:** first launch on a device with `.limited` access set in Settings;
   the app is fully usable over the selection.
2. **Storage honesty, Optimise Storage on:** pick a group of iCloud-only assets.
   The card shows both numbers. Commit. Device free space rises by roughly the
   *on-device* figure, iCloud usage by the *iCloud* figure. **These being
   confused is the most likely serious bug in the app.**
3. **Storage honesty, Download and Keep Originals:** the two numbers converge.
4. **Recently Deleted:** after commit, assets are in Recently Deleted and the
   pending figure matches. Empty it in Photos; device free space rises; the
   reclaimed report matches within a few percent.
5. **No network:** put the device in Airplane Mode and triage a library of
   iCloud-only assets. Grouping, scoring and the deck all work from local
   renditions. Instrument `PHImageRequestOptions` to assert
   `isNetworkAccessAllowed` is false on every grouping and scoring path.
6. **Bursts:** the suggested keeper matches `burstSelectionTypes` wherever a
   `.userPick` exists. Groups match what Photos itself shows.
7. **Screenshots:** the screenshot group matches the system Screenshots album.
8. **Scale:** a library of 20k+ assets. First card in under two seconds. Deck
   scrolling stays at 60 fps while prefetching. Memory flat over a 300-card run.
9. **Thermals:** run Stage B on a warm device; fingerprinting pauses at
   `.serious` and resumes. Low Power Mode suspends background work.
10. **Background:** schedule the fingerprint task, plug in overnight, confirm it
    ran and results are cached.
11. **Interruption:** kill the app mid-session. Relaunch returns to the same
    card with every decision intact.
12. **Undo:** at maximum depth, then commit, and confirm nothing undone was
    deleted.
13. **Guards:** confirm the app never proposes deleting a bracketed set or an
    original whose edit is kept.

### Release gates

- No commit path that deletes without the system confirmation.
- No code path that empties Recently Deleted.
- No network request on any grouping or scoring path.
- The cross-year regression test passes.

---

## 10. Open questions

1. **Video — accounting only, or triage too?** Proposal: accounting from Phase 0,
   triage deferred. Excluding it entirely would leave most of the phone's bytes
   invisible.
2. **`PHAssetResource` `fileSize` via KVC, or estimate only?** Same tradeoff as
   the Mac app: instant and undocumented, versus approximate and safe. Proposal:
   estimate by default, exact behind one swappable method, decide before App
   Store submission.
3. **dHash or `VNGenerateImageFeaturePrintRequest`?** Proposal: dHash first —
   fast, cheap on battery, good enough inside a time window — behind a protocol.
4. **Share `PickroomCore` with the Mac app, or duplicate?** Proposal: write it
   shareable, duplicate for now, revisit after both ship.
5. **Does `maybe` earn its place on a phone?** Four states may be one too many
   for a swipe deck. Consider shipping Phase 1 with keep / discard / skip and
   measuring whether `maybe` is missed.
6. **Should the app suggest turning on Optimise iPhone Storage?** It cannibalises
   part of the app's value. Proposal: yes — it is true, it is what a
   knowledgeable friend would say, and honesty buys the trust the delete flow
   needs.
