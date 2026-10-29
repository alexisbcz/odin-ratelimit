/*
Package ratelimit provides rate limiting primitives: a token bucket, a leaky
bucket, a sliding window log, a sliding window counter, a keyed limiter that
keeps one limiter per key, and thread-safe wrappers built on `core:sync`.

Every limiter reads time through a Clock. Pass the zero Clock to use the
monotonic system clock, or a Manual_Clock to drive time by hand in tests.

A limiter value is safe to use from one thread at a time. Wrap it in a
Sync_Limiter or Sync_Keyed_Limiter to share it between threads.

Example:
	import "core:time"
	import ratelimit "shared:ratelimit"

	main :: proc() {
		bucket: ratelimit.Token_Bucket
		err := ratelimit.token_bucket_init(&bucket, {
			capacity        = 10,
			refill_amount   = 1,
			refill_interval = time.Second,
		})
		if err != nil {
			return
		}
		if ratelimit.token_bucket_allow(&bucket) {
			// Handle the request.
		}
	}
*/
package ratelimit

import "base:runtime"
import "core:sync"
import "core:time"

/*
Config_Error lists the ways a limiter configuration can be invalid. Init
procedures return it before they touch any state or allocator.
*/
Config_Error :: enum {
	None,
	// A bucket capacity was less than 1.
	Invalid_Capacity,
	// A refill or leak amount was less than 1.
	Invalid_Amount,
	// A refill or leak interval was zero or negative.
	Invalid_Interval,
	// A sliding window limit was less than 1.
	Invalid_Limit,
	// A sliding window length was zero or negative.
	Invalid_Window,
	// A keyed limiter had a negative max_keys or idle_timeout.
	Invalid_Keyed_Config,
	// A Limiter_Config union held no variant.
	Missing_Config,
}

/*
Take_Error lists the ways a single take request can be rejected as malformed.
A request that is well formed but over the limit is not an error; it returns a
Decision with `allowed = false`.
*/
Take_Error :: enum {
	None,
	// The cost was less than 1.
	Invalid_Cost,
	// The cost is larger than the limiter can ever grant at once.
	Cost_Exceeds_Capacity,
	// The limiter was never initialized, or was destroyed.
	Not_Initialized,
	// A keyed limiter is full and no idle key could be pruned to make room.
	Too_Many_Keys,
}

/*
Error is the compound error type returned by every fallible procedure in this
package. `nil` means success. Compare it against a specific variant, such as
`Take_Error.Invalid_Cost`, or use a type switch.
*/
Error :: union #shared_nil {
	Config_Error,
	Take_Error,
	runtime.Allocator_Error,
}

/*
Decision is the outcome of a take request.

Fields:
- allowed: true when the request was granted and its cost was recorded.
- remaining: how many more units the limiter would grant right now.
- retry_after: when denied, how long until the same request would succeed; 0 when allowed.
- reset_after: how long until the limiter returns to its idle, fully available state.
- delay: for a Leaky_Bucket, how long the caller should wait before acting so that output stays smooth; 0 for every other limiter.
*/
Decision :: struct {
	allowed:     bool,
	remaining:   int,
	retry_after: time.Duration,
	reset_after: time.Duration,
	delay:       time.Duration,
}

/*
Clock_Proc returns the current time as a monotonic duration since an
arbitrary, fixed origin. `data` is the Clock's user pointer.
*/
Clock_Proc :: #type proc(data: rawptr) -> time.Duration

/*
Clock is an injectable time source. The zero value means the monotonic system
clock, so most callers never build one by hand.
*/
Clock :: struct {
	procedure: Clock_Proc,
	data:      rawptr,
}

// system_clock returns a Clock backed by the monotonic system tick counter.
system_clock :: proc() -> Clock {
	return Clock{procedure = system_clock_proc}
}

@(private = "file")
system_clock_proc :: proc(_: rawptr) -> time.Duration {
	return time.tick_diff(time.Tick{}, time.tick_now())
}

// clock_now reads `clock`, falling back to the system clock for the zero Clock.
clock_now :: proc(clock: Clock) -> time.Duration {
	if clock.procedure == nil {
		return system_clock_proc(nil)
	}
	return clock.procedure(clock.data)
}

/*
Manual_Clock is a clock that only moves when you move it, for deterministic
tests and simulations. Its zero value reads as 0. Reads and writes are
atomic, so one thread may advance it while others read it.
*/
Manual_Clock :: struct {
	nanoseconds: i64,
}

/*
manual_clock returns a Clock that reads `c`. The Clock keeps a pointer to `c`,
so `c` must outlive every limiter that uses it.
*/
manual_clock :: proc(c: ^Manual_Clock) -> Clock {
	return Clock{procedure = manual_clock_proc, data = c}
}

@(private = "file")
manual_clock_proc :: proc(data: rawptr) -> time.Duration {
	c := (^Manual_Clock)(data)
	return time.Duration(sync.atomic_load(&c.nanoseconds))
}

// manual_clock_advance moves `c` forward by `d`. A negative `d` moves it back.
manual_clock_advance :: proc(c: ^Manual_Clock, d: time.Duration) {
	sync.atomic_add(&c.nanoseconds, i64(d))
}

// manual_clock_set moves `c` to the absolute time `t`.
manual_clock_set :: proc(c: ^Manual_Clock, t: time.Duration) {
	sync.atomic_store(&c.nanoseconds, i64(t))
}

// manual_clock_now returns the time `c` currently reads.
manual_clock_now :: proc(c: ^Manual_Clock) -> time.Duration {
	return time.Duration(sync.atomic_load(&c.nanoseconds))
}

// ceil_div divides two non-negative numbers, rounding up.
@(private)
ceil_div :: proc "contextless" (a, b: i128) -> i128 {
	if a <= 0 {
		return 0
	}
	return (a + b - 1) / b
}

// to_duration converts a non-negative nanosecond count, saturating at the largest Duration.
@(private)
to_duration :: proc "contextless" (ns: i128) -> time.Duration {
	if ns <= 0 {
		return 0
	}
	if ns > i128(max(i64)) {
		return time.Duration(max(i64))
	}
	return time.Duration(ns)
}

// to_int converts a non-negative count, saturating at the largest int.
@(private)
to_int :: proc "contextless" (n: i128) -> int {
	if n <= 0 {
		return 0
	}
	if n > i128(max(int)) {
		return max(int)
	}
	return int(n)
}
