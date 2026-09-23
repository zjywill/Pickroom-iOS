# Pickroom for iOS

A fast photo triage app for iPhone. One gesture per decision, one decision per
set of near-identical shots.

**Status: implemented — Phases 0–5 built, 94 automated tests passing, awaiting
real-device verification.** The complete design lives in
[docs/PLAN.md](docs/PLAN.md); the shared algorithm design lives in
[Pickroom#1](https://github.com/zjywill/Pickroom/issues/1).

## What this is

[Pickroom](https://github.com/zjywill/Pickroom) on macOS is a keyboard-first RAW
culling workspace: a photographer sits down with a shoot and picks the keepers.

Pickroom for iOS is the same act — choosing your best photographs — on the
device where the problem actually lives. A phone ships with 128–256 GB and the
photo library routinely takes 50 GB of it. The person holding that phone has two
minutes in a queue, one thumb free, and fifty thousand photos they have never
looked at twice.

So the iOS app is built around **speed of decision**:

- Automatic grouping turns fifty thousand loose photos into a few thousand
  obviously-related sets.
- A best-shot suggestion puts the likely keeper on top of each set.
- One swipe resolves the whole set.

The user still makes every call. The app just makes each call take two seconds
instead of two minutes.

## What it is not about

Not about file sizes. A photo's worth has nothing to do with how many megabytes
it takes: a keeper stays at 25 MB, a blurred miss goes at 200 KB. The app looks
for photos that have **no reason to exist any more** — redundant frames, failed
shots, screenshots that stopped being useful months ago, exact duplicates — and
presents them cheapest-decision-first. Space comes back as a consequence, and
gets reported afterwards rather than promised in advance.

## How it differs from the Mac app

The photo library is the only source. There is no folder browsing, no RAW
decoding, no LibRaw, and no file management — an iPhone does not shoot Sony RAW,
and nothing on iOS lives outside the Photos library. That removes a large part
of the Mac app's surface and leaves room for the part that matters here: the
group-aware swipe deck.

One thing to be clear about, since the app is built on it: with iCloud Photos
on there is a single library, so deleting a photo here deletes it from iCloud and
every device signed into the account. There is no "remove from this phone only" —
the feature that does that is Optimise iPhone Storage, and the app says so.

Full comparison and rationale in [docs/PLAN.md](docs/PLAN.md).

## Building

Requirements: Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
xcodebuild -project Pickroom.xcodeproj -scheme Pickroom \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The platform-neutral core also runs directly:

```sh
cd Packages/PickroomCore && swift test
```

## What ships, phase by phase

| Phase | What | Where |
|---|---|---|
| 0 | Access flow incl. `.limited`, iCloud three-way diagnosis, Optimise Storage advice, Recently Deleted pending figure, deletability pre-filter, video counted and left alone | `Pickroom/App`, `Pickroom/Storage`, `Pickroom/Library/PhotoKitLibrary.swift` |
| 1 | The deck: card, four gestures, haptics, undo (whole-group steps, depth 100), decision persistence, session resume, prefetch, commit sheet + batch delete | `Pickroom/Triage` |
| 2 | Group engine: time clustering, `burstIdentifier`, brackets and versions guards, screenshot detection with time decay, per-group certainty, permanent dismissal | `PickroomCore/Grouping` |
| 3 | Best shot: burst-pick short circuit → face capture → aesthetics → fallback, normalised within the group, visible reasons, ties reported, one-tap keeper override | `PickroomCore/Ranking` |
| 4 | Near duplicates: `VNGenerateImageFeaturePrintRequest` (revision + crop pinned), candidates from Stage A time adjacency, floating threshold table, binary fingerprint cache with the revision guard, `BGProcessingTask` with thermal/Low Power throttling | `PickroomCore/Fingerprint`, `Pickroom/Library/AnalysisCoordinator.swift` |
| 5 | Review grid, decision filters, per-group detail, picks, the post-commit report, iPad layout, hardware keyboard on the deck (→ keep · ← discard · ↑ later · Space inspect · ⌘Z undo) | `Pickroom/Review`, `Pickroom/Triage/DeckView.swift` |

iOS-specific adaptations, documented in code where they live:

- **PhotoKit exposes no exposure bias**, so inside a burst, exposure-based
  badness never flags — that is the HDR-source signature, not a failed frame.
- **No Recently Deleted album is exposed to third parties**, so the pending
  figure is the app's own log of committed deletions. It is never emptied by
  the app.
- **`VNFeaturePrintObservation` cannot be reconstructed from cached data**, so
  distances run on the stored float vector (Euclidean). Threshold constants are
  provisional and calibrated to that metric.
- **Exact-duplicate hashes run over the deterministic 256 px analysis rendition**, not
  original bytes — identical originals hash equal; re-encoded copies from other
  devices are the near-duplicate engine's job.

## Verification status

Automated, all passing (55 core + 39 app layer):

- The cross-year case (identical fingerprints 365 days apart → no group), time
  clustering boundaries (midnight, timezone, degenerate clocks), the floating
  threshold, the revision guard, bracket and versions guards, failed-frame
  tiering (a shallow-DOF portrait is never flagged), oldest-first expired
  utility, video containment, cheapest-decision ordering, group identity across
  rescans, ranking and ties, undeletable assets never entering a batch, deck
  gesture/undo/resume semantics (including undo across an engine reload),
  commit wording that never understates a deletion's reach, the user's
  keeper and favourites never being pre-marked, withdrawing a deletion
  after relaunch, the append-only decision journal, analysis never
  resurrecting deleted assets.

Release gates, checked:

- One delete path only, through `performChanges` → the system's own
  confirmation for the entire batch.
- Nothing anywhere empties Recently Deleted.
- Analysis never uses the network: every analysis, thumbnail and metadata
  request has `isNetworkAccessAllowed = false`, and an iCloud-only photo is
  scored from its local thumbnail. The only network requests are the two a
  user starts by opening an item — a display-sized photo
  (`AssetImageProvider.displayImage`) and video playback — and both go into
  Photos' own purgeable cache, never the library.
- `.iTunesSynced` / `.cloudShared` assets are filtered at three layers.
- No bulk action exists for `probablyBad`, at any threshold.

**The Simulator cannot test** iCloud configuration, deletion propagation,
thermals, background scheduling, or scale — the plan's §10 manual checklist on a
real device (with a throwaway library; deletion is global) is required before
any release.

## Decisions do not sync

Both apps point at the same iCloud library, so deletions travel for free, but
`pick` and `maybe` are Pickroom's own state and stay on the device that made
them. Both apps say so plainly.
