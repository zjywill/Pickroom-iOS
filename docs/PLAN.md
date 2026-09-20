# Pickroom for iOS — Execution Plan

Companion to [zjywill/Pickroom](https://github.com/zjywill/Pickroom) (macOS) and
to its Auto Group design, [Pickroom#1](https://github.com/zjywill/Pickroom/issues/1).
That issue holds the shared algorithm design — grouping kinds, the time-first
similarity rule, best-shot ranking — and is **not repeated here**. This document
covers what is specific to iOS: what changes, what gets dropped, how the
interaction differs, and the phase-by-phase plan with verification.

---

## 1. Why an iOS app exists

The macOS app can only free space on a phone *indirectly*, through iCloud sync,
and only when iCloud Photos is on. On iOS the app acts on the device library
directly.

The second reason is the shape of the session. Mac culling is an hour at a desk.
Phone culling is three minutes in a queue, one-handed, interrupted. Every design
decision below follows from that difference.

### Positioning

Pickroom is a tool for choosing your best photographs. That does not change on
iOS. A full phone is *why* someone opens the app; picking keepers is *what* they
do in it.

Grouping and best shot are **triage that accelerates the user's own decision**,
never a decision made for them. On a phone that acceleration is the entire
product: without it, a fifty-thousand-photo library is not reviewable at all on
a six-inch screen.

### Size is not the axis

An early draft of this plan ranked everything by reclaimable bytes. That was
wrong, and the correction shapes the rest of the document.

**A photo's worth has no relationship to its size.** A keeper stays at 25 MB; a
blurred miss goes at 200 KB. Sorting by bytes sorts by *which files are large*,
which is a different set from *which photos should go*, and it puts the app in
the position of arguing that something should be deleted because it is big.

It also creates a trust problem that disappears the moment we stop: an app that
promises "frees 4.2 GB" can be contradicted by the Settings screen ten seconds
later (see §3). An app that says "14 near-identical shots — keep one?" is
telling the truth under every storage configuration there is.

So the app does not lead with byte counts, does not sort by them, and does not
promise them. Size keeps exactly two narrow jobs, in §3.

---

## 2. Scope relative to macOS

### Dropped entirely

| Mac capability | Why it goes |
|---|---|
| `RawEngine` / LibRaw | An iPhone does not shoot third-party RAW. ProRAW is DNG and ImageIO decodes it natively. This also removes the CDDL/LGPL licensing story, `Tools/build-libraw.sh`, the vendored framework, and its share of the release pipeline. |
| Folder source, `FolderAccess`, security-scoped bookmarks | Nothing on iOS lives outside the Photos library. |
| `RejectArchive` (moving files to a folder) | There is no user-visible filesystem. Rejection resolves to PhotoKit deletion instead. |
| `LocationSidecar`, `PhotoLocationWriter`, `LocationPickerView` | iPhone photos already carry GPS. |
| `SVGSupport` | Not a photo-library format. |
| Keyboard shortcuts (`CullingShortcuts`) | Replaced by gestures. Hardware-keyboard support on iPad can come back later. |
| Full-resolution zoom / focus inspection | Deliberately deferred. It is a desk activity. |

### Carried over as concepts, reimplemented

| Concept | iOS form |
|---|---|
| `PhotoDecision` | Same states, same semantics. Whether `maybe` earns its place on a phone is an open question. |
| `SelectionStore` | Same idea, keyed by `PHAsset.localIdentifier`. |
| `PreviewPipeline` | Replaced by `PHCachingImageManager` with a sliding prefetch window. |
| Group engine, best-shot ranking | **Same algorithms**, see §7. |
| `AssetSource` | Collapses to a single case. Keep the type anyway so core code stays platform-neutral. |

### New on iOS

- Deletion that is global by construction (§3).
- Batch deletion through one system confirmation.
- Limited-library access as a first-class state.
- Thermal and Low Power Mode throttling.
- Background fingerprinting while charging.
- Resume-exactly-where-you-were session state.

---

## 3. What deletion actually does

This has to be understood before any UI is drawn, because it determines what the
app is allowed to say.

### Deletion is global, and it is not a choice

With iCloud Photos on there is **one library**.
`PHAssetChangeRequest.deleteAssets` removes the asset from it, and that
propagates: iPhone, iPad, Mac, iCloud.com. Recently Deleted syncs too, so the
30-day grace period is one shared copy, not one per device.

With iCloud Photos off, the library is local and deletion affects only this
device.

There is no third option, and **no API for "remove from this phone but keep it
in iCloud."**

### The misconception the app will meet constantly

Users will want exactly that third option: *my phone is full, just move it off
my phone.* It sounds reasonable and it is the most common question this category
of app receives.

The feature that actually does it is **Optimise iPhone Storage** — iOS evicts
originals to iCloud and keeps a small rendition locally. That is precisely
"remove from phone, keep in iCloud", automatically.

So the app must be ready to answer this, and the answer is genuinely useful:

- **iCloud Photos on, Optimise Storage off** → say so on the first screen and
  link to Settings. Turning it on can free tens of gigabytes without deleting a
  single photo. It is the correct advice, it is what a knowledgeable friend
  would say, and giving it first buys the credibility the delete flow needs
  later. Check first that the iCloud plan can actually hold the library —
  advising it while iCloud is full helps nobody.
- **iCloud Photos on, Optimise Storage on** → the phone already evicts what it
  can. It is still full because 50,000 renditions at a few hundred KB each is
  still tens of gigabytes. Culling works; it just takes more photos to move the
  needle, which is exactly what group-at-a-time triage is for.
- **iCloud Photos off** → no automatic mechanism exists, deletion is the only
  lever, and it is 1:1. This is the cleanest case and the user this app serves
  best.

### Where size still matters — two narrow jobs

1. **The report afterwards.** "1,240 photos deleted" first, size second, and
   better than either: the device storage bar before and after, which the user
   already has an intuition for. This is evidence the session was worth it, not
   an input to any decision.
2. **Coverage, not ranking.** One minute of 4K60 video is roughly 400 MB, about
   130 HEIC stills. If the app is entirely size-blind, a user can spend a whole
   session on photos and move less than deleting three videos would. So video
   must be *surfaced as a category the user has not looked at*, on the grounds
   that it is unexamined — not on the grounds that it is big. Accounting only in
   Phase 0; playback and frame review are out of scope.

Note that under Optimise Storage a video's local rendition stays comparatively
large, so video is the one category where the device actually feels each
deletion.

### Recently Deleted

Space is not returned until it is emptied, 30 days by default. Show a live
"pending in Recently Deleted" figure and link to the Photos app. **Never empty it
automatically** — that is the one irreversible step and it belongs to the user.

### Live Photos

Each carries a ~3 second movie. PhotoKit cannot strip it in place, so the only
lever is deleting the asset.

---

## 4. What actually gets deleted

The app's job is to find photos that **no longer have a reason to exist**. There
are four such reasons, and none of them is size.

### 4.1 Redundancy

Bursts and re-shoots of one composition. One frame is enough. Highest volume,
and the reason grouping exists.

### 4.2 Failed frames

Out of focus, motion-blurred beyond use, a pocket shot of the floor, solid black
or white, an accidental shutter press. These are **objective** failures, and
almost nobody wants them.

Two properties make this category valuable out of proportion to its size:

- **It needs no grouping.** A single unusable photo with no siblings should still
  be surfaced. The earlier design only ranked *within* groups, so a lone bad
  frame would have sat in the library untouched forever. That was a real gap.
- **It is the cheapest decision in the whole app.** Whether a photo is in focus
  is not a matter of taste, unlike which of two smiles is better. It should come
  first (§4.5).

### 4.3 Expired utility images

Screenshots, receipts, QR codes, images saved from messaging apps. Useful when
saved, useless a week later.

The signal here is **time decay, and it has nothing to do with size**. A
screenshot from six months ago is almost certainly dead weight. So this category
is presented oldest-first and in bulk — "312 screenshots from 2024" as one
sweep is far more effective than reviewing them one at a time.

### 4.4 Exact duplicates

The same file stored twice. Unconditionally safe, and the only category where
time distance is irrelevant (see the time-first rule in §7).

### 4.5 Ordering: by certainty, not by bytes

Work is presented **cheapest decision first**.

A 14-frame burst is a two-second glance. Five different photos from one dinner
take real thought. The burst goes first — not because it saves more space, but
because it costs less attention. Users quit chores; the ordering must guarantee
that whenever they quit, real work is already done.

Rough order: failed frames → exact duplicates → bursts → expired utility images
→ near-duplicates → everything else.

Groups whose right answer is *keep all* — bracketed exposures, original plus
edit — are collapsed into a single card to swipe past, never a deletion prompt.
Proposing that someone delete their HDR source frames is how an app like this
loses a user permanently.

---

## 5. The core interaction: group-aware swipe triage

This is the part with no Mac equivalent, and the reason the iOS app is worth
building.

### The deck

One card at a time, full screen, thumb-driven:

- **Swipe right** — keep.
- **Swipe left** — discard.
- **Swipe up** — decide later.
- **Tap** — inspect larger, pinch to zoom.
- **Long press** — see the whole group.

Haptics on every commit. **No confirmation dialogs during triage** — the entire
value is rhythm, and a dialog every few seconds destroys it. Safety comes from
undo, and from the fact that nothing leaves the library until an explicit commit.

### One gesture resolves a whole group

The deck serves **groups**, not loose photos, and this is the central idea:

```
┌─────────────────────────┐
│                         │
│      best shot          │   14 near-identical shots
│      ★ sharpest         │
│                         │   ← keep this one, discard 13
│   ▫ ▫ ▪ ▫ ▫ ▫  +8       │   → keep all 14
└─────────────────────────┘   ↑ decide later
```

A burst of 14 is one card, not 14. The thumbnail strip is tappable to change the
keeper before deciding. The header describes the situation — "14 near-identical
shots", "312 screenshots from 2024" — and **does not lead with a size**.

A few hundred cards stand in for tens of thousands of photos. That is what makes
the library tractable on a phone.

### Undo

A persistent, thumb-reachable undo button, plus shake-to-undo. Undo steps back
through whole cards, so undoing a group restores all of its members at once.
Depth of at least 20.

### Progress

Progress is expressed in work remaining — "340 of 1,200 sets reviewed" — not in
gigabytes. A finishable task gets finished; a byte target quietly turns the whole
app back into an argument about size.

### Commit

Decisions accumulate locally. Nothing is deleted during triage. On commit:

1. **Pre-filter by `sourceType`.** Only `.userLibrary` assets can be deleted.
   `.iTunesSynced` assets cannot be deleted by PhotoKit at all, and
   `.cloudShared` assets belong to a shared album. `performChanges` is one
   transaction: **a single undeletable asset can fail a batch of 300.** These
   must be excluded from the candidate set long before the commit screen, not
   filtered at the last moment.
2. A review sheet — a grid of everything about to go, and wording that matches
   what will actually happen:

   > **Delete 1,240 photos from iCloud and all your devices**
   > They move to Recently Deleted and are erased permanently after 30 days.

   This is the one place in the app where the language should be heavy. Triage
   is deliberately frictionless, and the price of that is that this screen must
   be unambiguous. The user believes they are cleaning up their phone; they are
   in fact changing their entire photo library, and those are not the same thing
   in their head.
3. One `PHPhotoLibrary.performChanges` with `deleteAssets` for the whole batch.
   **iOS shows its own system confirmation — one alert for the entire batch.**
   Batching should be designed around this: it is a real advantage over deleting
   photo by photo.
4. Assets land in Recently Deleted; the pending figure updates; the user is told
   what remains to be done in the Photos app.

### Session shape

Phone culling is interrupted by definition:

- Every decision persists immediately. Killing the app loses nothing.
- Reopening returns to the exact card.
- A summary on return: "Last time: 412 photos reviewed."

---

## 6. Access, permissions, privacy

- Request `.readWrite`. Deletion needs it, and asking mid-flow is worse than
  asking up front with an explanation.
- **`.limited` is a first-class state on iOS**, far more common than on macOS.
  The app must work correctly over a limited selection and offer
  `presentLimitedLibraryPicker(from:)` rather than nagging. Set
  `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` so the system prompt does
  not fire on every launch.
- All analysis is on-device. No network, ever, for grouping or scoring — the
  macOS `allowsNetworkAccess: false` contract carries over verbatim. Say so in
  the UI; "automatically analyse my photos" is an alarming sentence without it.
- No analytics on photo content.

---

## 7. Architecture

```
Pickroom-iOS/
├── Packages/
│   └── PickroomCore/          # SPM, platform-neutral, no UIKit/AppKit
│       ├── Models/            # PhotoDecision, PhotoGroup, ShotScore
│       ├── Grouping/          # GroupEngine: time clustering, kinds, thresholds
│       ├── Ranking/           # ShotRanker protocol + scorers
│       ├── Quality/           # failed-frame detection (group-independent)
│       └── Fingerprint/       # dHash, candidate selection
└── Pickroom/
    ├── App/
    ├── Library/               # PhotoKitLibrary, ImageCache, deletability
    ├── Triage/                # the deck, gestures, undo, commit
    ├── Storage/               # iCloud state, Recently Deleted, the report
    └── Review/                # grid, filters, per-group detail
```

`PickroomCore` imports nothing but Foundation. Grouping and ranking are identical
to the Mac app's, so writing them platform-neutral from day one keeps extraction
possible later. **Do not set up a cross-repo dependency now** — duplicated logic
is cheaper than coupling two unshipped codebases. Revisit after both ship once.

### Technical choices

| Decision | Choice | Rationale |
|---|---|---|
| Minimum iOS | **18.0** | Gives `VNCalculateImageAestheticsScoresRequest` unconditionally (iOS 18+), so no availability gating. iOS 27 is current; 18 is a wide net. |
| UI | SwiftUI, UIKit where gestures demand it | The card deck may need `UIPanGestureRecognizer` for interruptible, velocity-accurate drags. Do not fight SwiftUI on this. |
| Concurrency | Swift 6 strict | New codebase, no migration cost. |
| Project generation | XcodeGen (`project.yml`) | Matches the Mac repo's convention. |
| Images | `PHCachingImageManager` | Mandatory at this scale; sliding window around the deck position. |
| Persistence | SQLite or a compact binary table | Tens of thousands of rows for decisions, fingerprints, scores. JSON will not hold. |

### Device constraints that do not exist on Mac

- **Memory.** Size the image cache from `ProcessInfo.physicalMemory`; drop under
  pressure.
- **Thermals.** Pause fingerprinting at `ProcessInfo.thermalState >= .serious`
  and in Low Power Mode. A culling app that heats the phone gets deleted.
- **Background.** Fingerprint via `BGProcessingTask` with
  `requiresExternalPower = true`. Ideally the work happens overnight on the
  charger and no progress bar is ever seen.

---

## 8. Algorithms — deltas only

Full design in [Pickroom#1](https://github.com/zjywill/Pickroom/issues/1).
What is different here:

**Time-first similarity is unchanged and non-negotiable.** Visual similarity is
computed only inside a capture session; a selfie from this year and one from next
year are never grouped however alike they look. The floating threshold table
carries over as-is. Exact duplicates are the sole exception.

**Failed-frame detection is new and runs without grouping.** Saliency-cropped
Laplacian variance for focus, histogram clipping for exposure, plus a
near-uniform-frame check for pocket shots. It scores every asset independently,
not just group members. Threshold must be conservative — a false positive here
proposes deleting a photo with no sibling to fall back on, which is the worst
error the app can make. Prefer missing bad frames over flagging good ones.

**Expired utility images are ranked by age, not similarity.** Detection is
`mediaSubtypes.contains(.photoScreenshot)` plus
`VNCalculateImageAestheticsScoresRequest.isUtility` (iOS 18+, unconditional at
this deployment target), then presented oldest-first in bulk sweeps.

**Best shot gets easier.** `PHAsset.burstSelectionTypes` (`.userPick` >
`.autoPick`) is more often populated on a device library than on a Mac's, and
costs nothing. Beyond that the ladder is unchanged: face capture quality, then
aesthetics, then the sharpness/exposure fallback — with the two rules that decide
whether it feels smart or broken: measure sharpness on the **subject** region,
not the whole frame, and normalise scores **within the group**.

**Scoring budget is tighter.** Score only cards near the current deck position,
on a ~512 px rendition, and cache. Battery is the budget, not milliseconds.

**Ordering** is by decision certainty (§4.5), so the group engine must emit a
confidence value per group and the deck must sort on it.

**RAW handling collapses.** ProRAW DNGs decode through ImageIO like anything
else.

---

## 9. Phases

Each phase ships something usable on its own.

### Phase 0 — Access and an honest picture of the situation

Scaffolding, XcodeGen, permission flow including `.limited`, iCloud
configuration detection, the three-way diagnosis from §3, the Optimise Storage
advice where it applies, the Recently Deleted pending figure, and deletability
filtering by `sourceType`.

Ships as one screen that tells the user **which situation they are in and what
will actually help** — including the case where the honest answer is "flip a
switch in Settings, don't delete anything". No triage yet, and still worth
installing.

### Phase 1 — The deck, over the zero-thought categories

The card, four gestures, haptics, undo, decision persistence, session resume,
`PHCachingImageManager` prefetch, the commit sheet and batch delete.

Served by **failed frames and exact duplicates** — the two categories that need
no grouping at all and whose decisions are cheapest. This proves the interaction
and delivers the least ambiguous deletions in the library on day one.

### Phase 2 — Grouping, and the group-aware card

`PickroomCore` Stage A: time clustering, `burstIdentifier`, `mediaSubtypes`,
bracket and version guards, screenshot and saved detection with time decay,
per-group confidence. The deck starts serving groups, ordered by certainty.
Permanent per-group dismissal.

This is the throughput multiplier on Phase 1.

### Phase 3 — Best shot

`ShotRanker`: `burstSelectionTypes` short circuit, then the fallback scorer,
then face capture quality, then aesthetics. Visible reason on every suggestion;
one-tap override that persists.

### Phase 4 — Near duplicates

dHash behind a protocol, candidates drawn only from Stage A's time-adjacent
sets, the floating threshold table, on-disk fingerprint cache keyed by
`localIdentifier` + modification date, `BGProcessingTask` with thermal and power
throttling.

### Phase 5 — Review and parity

Grid review, decision filters, per-group detail, a picks view, the post-empty
report, iPad layout, hardware keyboard support.

---

## 10. Verification

### What the Simulator cannot test

State this plainly, because it shapes the whole strategy. The iOS Simulator has
a small synthetic library and **cannot** exercise: iCloud Photos configuration,
Optimise Storage renditions, `PHImageResultIsInCloudKey`, deletion propagation to
other devices, shared libraries, thermal state, Low Power Mode, background task
scheduling, or realistic scale.

**Everything in §3 and every performance claim must be verified on a real
device.** The Simulator covers pure logic and UI layout, nothing more.

### Automated — `PickroomCore`, no library access

- **The cross-year case:** two assets with identical fingerprints 365 days apart
  produce **no** near-duplicate group. Write this first; the whole time-first
  design exists for it.
- Time clustering: gap exactly at threshold; a session crossing midnight stays
  one session; a timezone jump does not split it; degenerate all-zero timestamps
  fall back to identifier order.
- Floating threshold: the same fingerprint distance groups at 2 s and does not at
  2 h.
- Bracket guard: three frames at exposure bias −2/0/+2 within one second are
  `bracket` with a keep-all default, never a deletion prompt.
- Versions guard: an original and its edit never form a deletion prompt.
- **Failed-frame conservatism:** a shallow-depth-of-field portrait with a soft
  background is **not** flagged. This is the false positive that matters most.
- Expired-utility ordering: screenshots come back oldest-first.
- **Ordering by certainty:** given a mixed set, failed frames and exact
  duplicates precede bursts, which precede near-duplicates.
- Group identity: same members in a different order produce the same id; group
  state survives a rescan.
- Ranking: one sharp and two blurred frames rank the sharp one first; a tie
  inside 5% returns two candidates.

### Automated — app layer, Simulator

- Permission states render correctly: not determined, denied, `.limited`,
  authorised.
- Over a `.limited` selection the app triages only the selected assets and offers
  the limited-library picker.
- Deck gestures produce the expected decisions; undo restores a whole group in
  one step; decisions survive a process kill and relaunch.
- **`.iTunesSynced` and `.cloudShared` assets never enter the candidate set.**
- The commit sheet's count matches the pending rejects.

### Manual — real device, required before any release

Use a **test device or a throwaway library**. Deletion is real and global.

1. **Access:** first launch with `.limited` access; the app is fully usable over
   the selection.
2. **Diagnosis:** each of the three §3 configurations produces the correct
   first-screen message, including the Optimise Storage advice and its
   suppression when the iCloud plan cannot hold the library.
3. **Deletion is global:** commit a batch on the phone, then confirm the assets
   are gone from the Mac's Photos library and iCloud.com, and present in Recently
   Deleted on both.
4. **Batch integrity:** with `.iTunesSynced` assets present in the library,
   confirm a 300-asset batch commits without the transaction failing.
5. **Shared content:** determine empirically what happens to an iCloud Shared
   Photo Library asset — PhotoKit exposes no clear third-party flag for it, so
   this must be established on device, not inferred. **Gate the release on it:**
   deleting another participant's contribution is unacceptable.
6. **Recently Deleted:** the pending figure matches; emptying it in Photos
   raises free space; the report matches within a few percent.
7. **No network:** in Airplane Mode, triage a library of iCloud-only assets.
   Grouping, scoring and the deck all work from local renditions. Instrument
   `PHImageRequestOptions` to assert `isNetworkAccessAllowed` is false on every
   grouping and scoring path.
8. **Bursts:** the suggested keeper matches `burstSelectionTypes` wherever a
   `.userPick` exists.
9. **Screenshots:** the group matches the system Screenshots album; ordering is
   oldest-first.
10. **Scale:** 20k+ assets. First card under two seconds. 60 fps while
    prefetching. Flat memory over a 300-card run.
11. **Thermals:** fingerprinting pauses at `.serious` and resumes; Low Power Mode
    suspends background work.
12. **Background:** schedule the task, charge overnight, confirm it ran and
    results are cached.
13. **Interruption:** kill mid-session; relaunch returns to the same card with
    every decision intact.
14. **Undo** at maximum depth, then commit, and confirm nothing undone was
    deleted.

### Release gates

- No commit path that deletes without the system confirmation.
- No code path that empties Recently Deleted.
- No network request on any grouping or scoring path.
- No undeletable or shared asset can enter a delete batch.
- The cross-year regression test and the failed-frame conservatism test pass.

---

## 11. Open questions

1. **Video — accounting only, or triage too?** Proposal: accounting and category
   surfacing from Phase 0, triage deferred. A size-blind app would otherwise
   never mention the largest thing in the library.
2. **dHash or `VNGenerateImageFeaturePrintRequest`?** Proposal: dHash first —
   fast, cheap on battery, good enough inside a time window — behind a protocol.
3. **Share `PickroomCore` with the Mac app, or duplicate?** Proposal: write it
   shareable, duplicate for now, revisit after both ship.
4. **Does `maybe` earn its place on a phone?** Four states may be one too many
   for a swipe deck. Consider shipping Phase 1 with keep / discard / skip and
   measuring whether `maybe` is missed.
5. **Should decisions sync between the iOS and macOS apps?** They point at the
   same iCloud library, so a photo deleted on the phone is gone on the Mac — but
   `pick` and `maybe` are Pickroom's own state and do not travel. A user who
   culls on both will review the same photos twice. CloudKit would fix it and
   brings conflict resolution with it. Proposal: do not build it; state plainly
   in both apps that decisions are local; revisit if anyone complains.
6. **How aggressive should failed-frame detection be?** It is the only category
   that can propose deleting a photo with no sibling. Proposal: start
   deliberately conservative and loosen only with real-library evidence.
