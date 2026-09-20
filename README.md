# Pickroom for iOS

A fast photo triage app for iPhone. One gesture per decision, one decision per
group of near-identical shots, and a running count of the storage you get back.

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
- A live counter shows the gigabytes coming back.

The user still makes every call. The app just makes each call take two seconds
instead of two minutes.

## How it differs from the Mac app

The photo library is the only source. There is no folder browsing, no RAW
decoding, no LibRaw, and no file management — an iPhone does not shoot Sony RAW,
and nothing on iOS lives outside the Photos library. That removes a large amount
of the Mac app's surface and leaves room for the part that matters here.

Full comparison and rationale in [docs/PLAN.md](docs/PLAN.md).
