# Contributing to kith

Thanks for the interest. Some notes to make a contribution land smoothly.

## Dev setup

```sh
git clone https://github.com/supaku/kith.git
cd kith
swift build
swift test          # 79+ tests, ~0.5s, no TCC grants needed
```

The non-CN suites use in-memory SQLite; the `kithTests` integration suite shells the built binary against an on-disk fixture DB via `KITH_DB_PATH`. None of the tests require real Contacts or Full Disk Access grants on your machine.

## Project layout

See [README.md → Layout](./README.md#layout) for the canonical map.

The locked architectural decisions live in `.claude/PLAN.md`. Significant deviations should be discussed in an issue first — the plan is the source of truth for "what we promised."

## Vendored code

`Sources/MessagesCore/` is a vendor copy from [imsg](https://github.com/steipete/imsg) (MIT). Don't edit those files in place. To re-sync:

```sh
scripts/vendor-sync.sh
```

kith-specific extensions go in `Sources/MessagesCore/Extensions/` so they survive a re-sync.

## Filing an issue

- For a bug: include `kith doctor --json` output, the exact command you ran, and the observed vs. expected behavior.
- For a feature: lead with the use case, not the implementation.

## Pull requests

- Open against `main`. Keep PRs focused — one change per PR is easier to review.
- All tests must pass (`swift test`); CI also runs on every PR.
- New behavior should ship with tests. The existing test patterns (`FixtureDB`, `FakeContactsStore`) are easy to extend.
- Follow the existing code style; we're not running a formatter, so stay close to surrounding conventions.

## Releasing

See [RELEASING.md](./RELEASING.md) for how releases get cut and how the Homebrew tap gets updated.

## Code of conduct

This project follows the [Contributor Covenant v2.1](./CODE_OF_CONDUCT.md). Be kind.
