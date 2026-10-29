# ratelimit

[![CI](https://github.com/alexisbcz/odin-ratelimit/actions/workflows/ci.yml/badge.svg)](https://github.com/alexisbcz/odin-ratelimit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--09-1e5a99.svg)](https://odin-lang.org)

Rate limiting for Odin: token bucket, leaky bucket, sliding window log, sliding window counter and a per-key limiter, all with a replaceable clock for deterministic tests and thread-safe wrappers.

## Install

The repository root is the package, so you can vendor it in two ways.

As a Git submodule inside your project:

```sh
git submodule add https://github.com/alexisbcz/odin-ratelimit libs/ratelimit
```

```odin
import "libs/ratelimit"
```

As a copy in a shared collection that all your projects use:

```sh
git clone https://github.com/alexisbcz/odin-ratelimit ~/odin-shared/ratelimit
odin build . -collection:shared=$HOME/odin-shared
```

```odin
import "shared:ratelimit"
```

## Quick start

```odin
package main

import "core:fmt"
import "core:time"
import "shared:ratelimit"

main :: proc() {
	// Bursts of up to 10 requests, refilled at 5 per second.
	bucket: ratelimit.Token_Bucket
	err := ratelimit.token_bucket_init(&bucket, {
		capacity        = 10,
		refill_amount   = 5,
		refill_interval = time.Second,
	})
	if err != nil {
		fmt.eprintln("bad config:", err)
		return
	}

	decision, _ := ratelimit.token_bucket_take(&bucket)
	if decision.allowed {
		fmt.println("allowed,", decision.remaining, "left")
	} else {
		fmt.println("slow down, retry in", decision.retry_after)
	}
}
```

Limit each client separately with a `Keyed_Limiter`, and share it between threads with `Sync_Keyed_Limiter`:

```odin
clients: ratelimit.Sync_Keyed_Limiter
err := ratelimit.sync_keyed_limiter_init(&clients, {
	limiter      = ratelimit.Sliding_Window_Counter_Config{limit = 100, window = time.Minute},
	max_keys     = 100_000,
	idle_timeout = 10 * time.Minute,
})
if err != nil {
	return
}
defer ratelimit.sync_keyed_limiter_destroy(&clients)

if !ratelimit.sync_keyed_limiter_allow(&clients, client_ip) {
	// Reply with HTTP 429.
}
```

## Choosing an algorithm

| Limiter | Memory | Behavior | Pick it when |
| --- | --- | --- | --- |
| `Token_Bucket` | Constant | Allows bursts up to `capacity`, then a steady rate | You want an average rate with some slack |
| `Leaky_Bucket` | Constant | Queues requests and returns a `delay` that spaces them evenly | You call a service that needs smooth traffic |
| `Sliding_Window_Log` | `limit` timestamps | Exact: never more than `limit` in any `window` | Limits are small and must be exact |
| `Sliding_Window_Counter` | Constant | Estimates a sliding window from two fixed windows | Limits are large, or you track many keys |

Every `take` procedure returns a `Decision`:

- `allowed`: whether the request went through.
- `remaining`: how many more units the limiter would grant now, for headers such as `RateLimit-Remaining`.
- `retry_after`: when denied, how long until the same request succeeds, for the `Retry-After` header.
- `reset_after`: how long until the limiter is fully available again.
- `delay`: for a `Leaky_Bucket`, how long to wait before acting.

## Testing with a manual clock

Every limiter reads time through a `Clock`. The zero `Clock` is the monotonic system clock. Pass a `Manual_Clock` to control time in tests:

```odin
clock: ratelimit.Manual_Clock
bucket: ratelimit.Token_Bucket
_ = ratelimit.token_bucket_init(
	&bucket,
	{capacity = 1, refill_amount = 1, refill_interval = time.Second},
	ratelimit.manual_clock(&clock),
)
_ = ratelimit.token_bucket_allow(&bucket)        // true
_ = ratelimit.token_bucket_allow(&bucket)        // false
ratelimit.manual_clock_advance(&clock, time.Second)
_ = ratelimit.token_bucket_allow(&bucket)        // true again
```

To plug in another time source, build a `Clock` with your own `Clock_Proc` and data pointer.

## API overview

| Declaration | Purpose | Allocates | Free with |
| --- | --- | --- | --- |
| `token_bucket_init(b, config, clock)` | Prepare a `Token_Bucket` | No | Not needed |
| `leaky_bucket_init(b, config, clock)` | Prepare a `Leaky_Bucket` | No | Not needed |
| `sliding_window_log_init(l, config, clock, allocator)` | Prepare a `Sliding_Window_Log` | Yes | `sliding_window_log_destroy` |
| `sliding_window_counter_init(c, config, clock)` | Prepare a `Sliding_Window_Counter` | No | Not needed |
| `*_take(x, cost)` | Ask for `cost` units and get a `Decision` | No | Not needed |
| `*_allow(x)` | Ask for one unit and get a `bool` | No | Not needed |
| `*_reset(x)` | Return a limiter to its starting state | No | Not needed |
| `limiter_init(l, config, clock, allocator)` | Build any algorithm from a `Limiter_Config` | Only for a log | `limiter_destroy` |
| `keyed_limiter_init(k, config, clock, allocator)` | One limiter per key, created on first use | Yes | `keyed_limiter_destroy` |
| `keyed_limiter_prune(k)` | Drop keys idle for `idle_timeout` | No | Not needed |
| `sync_limiter_init`, `sync_keyed_limiter_init` | Mutex-guarded versions for shared use | Like the inner limiter | `sync_*_destroy` |
| `Manual_Clock`, `manual_clock(c)` | A clock that only moves when you move it | No | Not needed |
| `Error` | Union of `Config_Error`, `Take_Error` and `runtime.Allocator_Error` | No | Not needed |

## Examples

Each directory under `examples/` is a runnable program:

```sh
odin run examples/basic
```

## Design notes

- All arithmetic uses integer nanoseconds widened to `i128`, so refills are exact and `retry_after` is never off by a rounding error.
- A malformed request, such as a cost of 0 or a cost larger than the limit, returns a `Take_Error`. A request that is only over the limit returns `allowed = false` with no error.
- A clock that moves backwards never grants extra capacity.
- `Keyed_Limiter` copies keys, so you can free a key right after the call. When it reaches `max_keys`, it prunes idle keys and returns `.Too_Many_Keys` if that frees no room.
- Plain limiters are safe to use from one thread at a time. The `Sync_` wrappers hold a `sync.Mutex` for each call. `Manual_Clock` uses atomics, so tests may advance it from any thread.
- The package keeps no global state and starts no threads.

## Testing

```sh
odin check . -vet -strict-style -disallow-do -no-entry-point
odin test tests -vet -strict-style -disallow-do
vale sync && vale *.md
```

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md). Commits follow Conventional Commits, and every change that users can see gets a line in [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
