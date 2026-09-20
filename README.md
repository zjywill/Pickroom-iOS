# Pickroom for iOS

A fast photo triage app for iPhone. One gesture per decision, one decision per
set of near-identical shots.

**Status: planning.** There is no code yet. The complete execution plan lives in
[docs/PLAN.md](docs/PLAN.md).

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
and nothing on iOS lives outside the Photos library. That removes a large part of
the Mac app's surface and leaves room for the part that matters here.

One thing to be clear about, since the app is built on it: with iCloud Photos
on there is a single library, so deleting a photo here deletes it from iCloud and
every device signed into the account. There is no "remove from this phone only" —
the feature that does that is Optimise iPhone Storage, and the app will say so.

Full comparison and rationale in [docs/PLAN.md](docs/PLAN.md).
