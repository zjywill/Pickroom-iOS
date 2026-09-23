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

### Positioning: taking out the garbage, not electing winners

The macOS app is a photographer picking keepers out of a shoot. This one is not
that, and the difference runs through every screen.

Someone opening this app on a full phone is not curating a portfolio. They are
looking for the shots that should never have been kept: the blurred ones, the
eight near-identical frames where one would do, the screenshot of a parking
space from 2024. The question they answer thousands of times is *does this
deserve to stay*, not *is this my best work*.

That decides what the app is allowed to assert. **"This frame is out of focus"
is objective and the app can say it. "This is the better of these two smiles" is
not, and it belongs to the user.** So every automatic judgement here points at
the bottom of the pile, never the top — which is also the safer direction to be
wrong in.

Best shot still exists, but its name oversells it: it picks the thumbnail that
represents a card, and its real value is the *other* end of the ranking, where
frames are definitively bad. **The default action on a group is "remove what is
clearly bad", not "keep one and discard the rest".** The app knows those eight
are blurred. It does not know that the remaining six should be reduced to one —
that is the user's call, offered as a secondary action and never taken
automatically.

Grouping and scoring are **triage that accelerates the user's own decision**,
never a decision made for them. On a phone that acceleration is the entire
product: without it a fifty-thousand-photo library is not reviewable at all on a
six-inch screen.

### First pass, not last

Removing the failures leaves the good ones — both framings end at the same set.
What differs is intent, and intent sets how certain the app must be before it
acts.

The workflow this is built for: **what Pickroom rejects gets deleted; what
survives goes on to be worked on properly.** On the Mac that means Photoshop or
Lightroom at 100% on a large screen. On a phone it means the photo simply stays,
and gets edited or shared whenever it comes up. Either way the fine judgement —
which of six good frames is the one — happens *after* Pickroom, with more
information than Pickroom has.

So the app's job ends at "this is clearly out", and everything else passes
through. **A generous survivor set is correct here, not lazy.** Leaving six
near-identical good frames costs the user almost nothing, and forcing a choice
between them would mean deciding with less information than the next stage will
have. The asymmetry is the whole design: be confident about removal, be generous
about survival.

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
   130 HEIC stills. If the app is entirely size-blind it never mentions the
   largest thing in the library at all. So video is counted and shown as its own
   filterable category — on the grounds that it is unexamined, not that it is
   big. What the app does *not* do with it is §4.6.

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

Bursts and re-shoots of one composition. Highest volume, and the reason grouping
exists.

Note what the app claims here and what it does not. It can say *these eight of
the fourteen are blurred or have someone blinking* — objective, and they go. It
cannot say which of the remaining six is the keeper, so it does not: they all
stay unless the user chooses to reduce further. Reducing a clean burst to one
frame is offered, never assumed.

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
  first (§4.6).

**Two tiers, because the presentation decides how strict the threshold has to
be.** This is the only category that can propose deleting a photo with no
sibling to fall back on, so the asymmetry is stark: a missed bad frame costs
nothing, a false positive costs something irreplaceable. But that cost depends
entirely on what the app *does* with the flag.

- **`obviouslyBroken`** — near-zero variance across the entire frame: solid
  black, solid white, a covered lens, a shutter pressed inside a bag. These are
  not photographs of anything. Safe to sweep in bulk, still shown as a grid
  before it commits.
- **`probablyBad`** — out of focus, motion-blurred, severely clipped.
  **Ordering only, never a proposal.** These are floated to the front of the
  deck and reviewed one card at a time, so a false positive costs two seconds
  and a swipe rather than a photo.

Splitting them is what lets the second tier be generous. A single threshold
would have to be strict enough to survive bulk deletion, and would therefore
catch almost nothing worth catching.

**There is no button that deletes `probablyBad` in bulk, at any threshold.**

### 4.3 Expired utility images

Screenshots, receipts, QR codes, images saved from messaging apps. Useful when
saved, useless a week later.

**Screen recordings belong here too**, not with video.
`mediaSubtypes.contains(.videoScreenRecording)` (iOS 13+) is authoritative, and
a screen recording is a screenshot that moves: captured to show someone
something, dead a week later, and nobody needs to watch it back to know that.
It is the one kind of video this app makes a judgement about.

The signal here is **time decay, and it has nothing to do with size**. A
screenshot from six months ago is almost certainly dead weight. So this category
is presented oldest-first and in bulk — "312 screenshots from 2024" as one
sweep is far more effective than reviewing them one at a time.

### 4.4 Exact duplicates

The same file stored twice. Unconditionally safe, and the only category where
time distance is irrelevant (see the time-first rule in §7).

### 4.5 Video, deliberately left alone

Everything except screen recordings is shown as a category and otherwise not
touched: no grouping, no best shot, no deletion proposals.

The reason is that **a poster frame tells you almost nothing about a video.** A
photo's thumbnail is the photo; a video's first frame may be black, or the
floor. Metadata heuristics do not close that gap either — a two-second clip
looks like a misfire and may be the only footage of something, a twenty-minute
recording looks like a forgotten camera and may be a recital. Whatever the app
says, the user will want to watch it before deciding, and it is right that they
should.

So the app does not pretend. Video gets a category and a count so the user knows
it is there and can work through it themselves; viewing happens in Photos.
Inline playback is out of scope — it is a different product surface (AVPlayer,
scrubbing, keyframe extraction, memory) and doing it badly would be worse than
handing off.

### 4.6 Ordering: by certainty, not by bytes

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
- **"Whole set" button** — see the whole group. No gesture in the app is a hidden long press; in every grid a tap marks a photo (tap again to keep), and a corner button opens it large.

Haptics on every commit. **No confirmation dialogs during triage** — the entire
value is rhythm, and a dialog every few seconds destroys it. Safety comes from
undo, and from the fact that nothing leaves the library until an explicit commit.

### One gesture resolves a whole group

The deck serves **groups**, not loose photos, and this is the central idea:

```
┌─────────────────────────┐
│                         │
│      clean frame        │   14 shots · 8 blurred or blinking
│                         │
│                         │   ← discard the 8 bad ones
│   ▫ ✕ ▫ ✕ ✕ ▫  +8       │   → keep all 14
└─────────────────────────┘   ↑ decide later
```

A burst of 14 is one card, not 14. The card leads with what the app is confident
about — which frames are objectively bad — and those are the ones the primary
gesture removes. **"Reduce to one" is a secondary action**, reachable by long
press, because picking the single keeper out of several good frames is the
user's judgement, not the app's.

The thumbnail strip is tappable to change any frame's mark before deciding. The
header describes the situation — "14 shots, 8 blurred", "312 screenshots from
2024" — and **does not lead with a size**.

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
│       └── Fingerprint/       # feature prints, candidate selection
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
not just group members. Two tiers — `obviouslyBroken` (degenerate frames, bulk
safe) and `probablyBad` (ordering signal only) — see §4.2 for why the split is
what makes the second tier affordable.

**Expired utility images are ranked by age, not similarity.** Detection is
`mediaSubtypes.contains(.photoScreenshot)` and `.videoScreenRecording`, plus
`VNCalculateImageAestheticsScoresRequest.isUtility` (iOS 18+, unconditional at
this deployment target), then presented oldest-first in bulk sweeps. Screen
recordings are the only video the engine classifies; see §4.5.

**Best shot gets easier.** `PHAsset.burstSelectionTypes` (`.userPick` >
`.autoPick`) is more often populated on a device library than on a Mac's, and
costs nothing. Beyond that the ladder is unchanged: face capture quality, then
aesthetics, then the sharpness/exposure fallback — with the two rules that decide
whether it feels smart or broken: measure sharpness on the **subject** region,
not the whole frame, and normalise scores **within the group**.

**Scoring budget is tighter.** Score only cards near the current deck position,
on a ~512 px rendition, and cache. Battery is the budget, not milliseconds.

**Ordering** is by decision certainty (§4.6), so the group engine must emit a
confidence value per group and the deck must sort on it.

**RAW handling collapses.** ProRAW DNGs decode through ImageIO like anything
else.

---

## 9. Phases

Each phase ships something usable on its own.

### Phase 0 — Access and an honest picture of the situation

Scaffolding, XcodeGen, permission flow including `.limited`, iCloud
configuration detection, the three-way diagnosis from §3, the Optimise Storage
advice where it applies, the Recently Deleted pending figure, deletability
filtering by `sourceType`, and video fetched and counted as its own category
(§4.5) — no video features beyond that.

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

`VNGenerateImageFeaturePrintRequest` behind a protocol, candidates drawn only
from Stage A's time-adjacent sets, the floating threshold table calibrated
against real libraries, on-disk fingerprint cache keyed by `localIdentifier` +
modification date + **request revision + crop-and-scale option**,
`BGProcessingTask` with thermal and power throttling.

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
- **Revision guard:** a cached fingerprint recorded under a different request
  revision or crop-and-scale option is discarded and recomputed, never compared.
- Bracket guard: three frames at exposure bias −2/0/+2 within one second are
  `bracket` with a keep-all default, never a deletion prompt.
- Versions guard: an original and its edit never form a deletion prompt.
- **Failed-frame tiering:** a shallow-depth-of-field portrait with a soft
  background is **not** flagged at all — the false positive that matters most. A
  soft-focus frame lands in `probablyBad` and is never offered for bulk action; a
  solid-black frame lands in `obviouslyBroken`.
- Expired-utility ordering: screenshots come back oldest-first.
- **Video containment:** a screen recording classifies as `expiredUtility`; every
  other video is counted in the video category and enters **no** group, no
  ranking, and no deletion proposal.
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
   oldest-first. Screen recordings appear alongside them.
10. **Video:** the video category count matches the library, and no video other
    than a screen recording is ever proposed for deletion anywhere in the app.
11. **Scale:** 20k+ assets. First card under two seconds. 60 fps while
    prefetching. Flat memory over a 300-card run.
12. **Thermals:** fingerprinting pauses at `.serious` and resumes; Low Power Mode
    suspends background work.
13. **Background:** schedule the task, charge overnight, confirm it ran and
    results are cached.
14. **Interruption:** kill mid-session; relaunch returns to the same card with
    every decision intact.
15. **Undo** at maximum depth, then commit, and confirm nothing undone was
    deleted.

### Release gates

- No commit path that deletes without the system confirmation.
- No code path that empties Recently Deleted.
- No network request on any grouping or scoring path.
- No undeletable or shared asset can enter a delete batch.
- The cross-year regression test and the failed-frame tiering test pass.
- No bulk action exists for `probablyBad`.

---

## 11. Decisions taken

Recorded so they are not relitigated.

**Video is categorised, not triaged.** Only screen recordings get a judgement,
and they join expired utility images rather than video. Everything else is
counted, filterable, and otherwise left alone, because a poster frame cannot
support the decision and the user will rightly want to watch first. Rationale in
§4.5. Inline playback is out of scope.

**Failed-frame detection has two tiers.** `obviouslyBroken` — degenerate frames
with near-zero variance, which are not photographs of anything — can be swept in
bulk behind a review grid. `probablyBad` is an ordering signal only and is never
proposed for deletion, which is exactly what lets its threshold be generous: a
false positive costs a swipe, not a photo. No bulk action on `probablyBad` at
any threshold. Rationale in §4.2.

**Near-duplicate matching uses `VNGenerateImageFeaturePrintRequest`, not
dHash.** The argument for dHash was cost, and the design removed it: Stage B
fingerprints only time-adjacent candidates, which in a 50,000 asset library is a
few thousand images, not fifty thousand.

dHash is a pixel-layout hash — an 8×8 reduction compared on gradient direction.
It is good at "same image, re-encoded", and weak at exactly what this app must
judge: same composition, subject moved slightly. A burst frame where someone
shifted their weight is semantically one photograph and can sit a long way away
in Hamming distance. The failure mode is the silent one — groups that never
appear, so the user concludes the app does not do much.

Three costs that must be designed for:

- **Revision pinning.** `VNGenerateImageFeaturePrintRequestRevision1` (iOS 13+)
  and `Revision2` (iOS 17+) produce **incomparable** prints — the header lists
  comparing non-comparable feature prints as an error case. The cache stores the
  revision, and an OS upgrade can invalidate all of it. On a phone that means a
  full recompute, so it must be schedulable through `BGProcessingTask` rather
  than run in the foreground.
- **`imageCropAndScaleOption` must be pinned** and included in the cache key.
- **The threshold table's units change.** The shape survives — looser when close
  in time, off entirely past an hour — but every number must be calibrated
  against real libraries, not guessed.

Cache entries grow from 8 bytes to a float vector, which stays affordable only
because candidates are pre-narrowed by time — and on a device where the app's
whole purpose is reclaiming storage, its own cache size is not a detail to wave
past. Keep the descriptor behind a protocol for substitutability, not because a
swap is planned; dHash is not being written.

**The deployment floor is roughly *current minus two*, which iOS 18 already
satisfies.** iOS 27 is current and 18 shipped September 2024, two releases back
(18 → 26 → 27). It gives `VNCalculateImageAestheticsScoresRequest` —
`overallScore` and the `isUtility` flag — with no `#available` gating, which is
the only version-dependent API this plan relies on. Nothing changes here.

The macOS app is on the same policy and rises from 14 to 15 during its Phase 3,
so both floors end up the same vintage. See
[Pickroom#1](https://github.com/zjywill/Pickroom/issues/1).

**Decisions do not sync between the iOS and macOS apps.** Both point at the same
iCloud library, so deletions travel for free, but `pick` and `maybe` are
Pickroom's own state and stay on the device that made them. Both apps say so
plainly. CloudKit would solve it and bring permanent conflict-resolution
complexity to two unshipped apps; the cheap fallback, if anyone ever complains,
is a Pickroom album in the photo library itself — albums sync through iCloud
Photos with no infrastructure at all (`PHAssetCollectionChangeRequest`).

---

## 12. Open questions

1. **Share `PickroomCore` with the Mac app, or duplicate?** Proposal: write it
   shareable, duplicate for now, revisit after both ship.
2. **Does `maybe` earn its place on a phone?** Four states may be one too many
   for a swipe deck. Consider shipping Phase 1 with keep / discard / skip and
   measuring whether `maybe` is missed.
