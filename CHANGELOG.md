# Changelog

This file records all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-10-29

### Added

- `sync_keyed_limiter_contains` and `sync_keyed_limiter_clear`, so shared users need not bypass the lock.

### Fixed

- `Keyed_Limiter` pruning, by hand or at `max_keys`, no longer removes a key whose limiter is still holding back requests. Before, a client could get a fresh limit by staying idle for `idle_timeout`.
- A `Keyed_Limiter` at `max_keys` no longer scans every key for each request with an unknown key. It skips the scan until a key can go stale.

## [0.1.0] - 2026-10-29

### Added

- `Token_Bucket` with continuous integer refills and an optional empty start.
- `Leaky_Bucket` that queues requests and reports a `delay` to space them evenly.
- `Sliding_Window_Log` for exact sliding window limits.
- `Sliding_Window_Counter` for constant-memory sliding window estimates.
- `Limiter` and `Limiter_Config` to use any algorithm behind one API.
- `Keyed_Limiter` with per-key limiters, `max_keys` and idle key pruning.
- `Sync_Limiter` and `Sync_Keyed_Limiter`, guarded by `sync.Mutex`.
- `Decision` results with `remaining`, `retry_after`, `reset_after` and `delay`.
- A replaceable `Clock`, plus `Manual_Clock` for deterministic tests.
- `Config_Error`, `Take_Error` and the compound `Error` union.

[Unreleased]: https://github.com/alexisbcz/odin-ratelimit/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/alexisbcz/odin-ratelimit/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alexisbcz/odin-ratelimit/releases/tag/v0.1.0
