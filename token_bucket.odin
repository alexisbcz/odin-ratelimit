package ratelimit

import "core:time"

/*
Token_Bucket_Config describes a token bucket.

Fields:
- capacity: the most tokens the bucket holds, which is also the largest burst; at least 1.
- refill_amount: how many tokens are added every `refill_interval`; at least 1.
- refill_interval: the period of `refill_amount`; must be positive.
- start_empty: when true the bucket starts with no tokens instead of a full bucket.

Tokens refill continuously, not in steps: with `refill_amount = 10` and
`refill_interval = time.Second`, one token arrives every 100 milliseconds.
*/
Token_Bucket_Config :: struct {
	capacity:        int,
	refill_amount:   int,
	refill_interval: time.Duration,
	start_empty:     bool,
}

/*
Token_Bucket grants requests while it holds tokens and refills at a fixed
rate. It allows bursts up to its capacity and an average rate of
`refill_amount / refill_interval`.

It allocates nothing, so it needs no destroy procedure. Create one with
token_bucket_init. A Token_Bucket is safe to use from one thread at a time.
*/
Token_Bucket :: struct {
	config: Token_Bucket_Config,
	clock:  Clock,
	// Tokens scaled by refill_interval, so refills stay exact in integers.
	level:  i128,
	last:   time.Duration,
}

// token_bucket_config_validate reports whether `config` describes a usable bucket.
token_bucket_config_validate :: proc(config: Token_Bucket_Config) -> Error {
	if config.capacity < 1 {
		return .Invalid_Capacity
	}
	if config.refill_amount < 1 {
		return .Invalid_Amount
	}
	if config.refill_interval <= 0 {
		return .Invalid_Interval
	}
	return nil
}

/*
token_bucket_init validates `config` and prepares `b`. The zero `clock` means
the system clock.

Returns:
- err: a Config_Error when `config` is invalid, in which case `b` is left untouched.
*/
token_bucket_init :: proc(b: ^Token_Bucket, config: Token_Bucket_Config, clock := Clock{}) -> (err: Error) {
	token_bucket_config_validate(config) or_return
	b.config = config
	b.clock = clock
	token_bucket_reset(b)
	return nil
}

// token_bucket_reset refills `b` to its starting state as of the current time.
token_bucket_reset :: proc(b: ^Token_Bucket) {
	b.last = clock_now(b.clock)
	b.level = 0 if b.config.start_empty else token_bucket_full(b)
}

/*
token_bucket_take tries to remove `cost` tokens from `b`.

Returns:
- decision: whether the tokens were taken, how many remain and when to retry.
- err: `.Invalid_Cost` when `cost < 1`, `.Cost_Exceeds_Capacity` when `cost` is
  larger than the capacity, or `.Not_Initialized`. On error nothing changes.
*/
token_bucket_take :: proc(b: ^Token_Bucket, cost := 1) -> (decision: Decision, err: Error) {
	if b.config.refill_interval <= 0 {
		return {}, .Not_Initialized
	}
	if cost < 1 {
		return {}, .Invalid_Cost
	}
	if cost > b.config.capacity {
		return {}, .Cost_Exceeds_Capacity
	}
	token_bucket_refill(b, clock_now(b.clock))

	interval := i128(b.config.refill_interval)
	amount := i128(b.config.refill_amount)
	need := i128(cost) * interval
	if b.level >= need {
		b.level -= need
		decision.allowed = true
	} else {
		decision.retry_after = to_duration(ceil_div(need - b.level, amount))
	}
	decision.remaining = to_int(b.level / interval)
	decision.reset_after = to_duration(ceil_div(token_bucket_full(b) - b.level, amount))
	return
}

// token_bucket_allow takes one token and reports whether it succeeded.
token_bucket_allow :: proc(b: ^Token_Bucket) -> bool {
	decision, err := token_bucket_take(b, 1)
	return err == nil && decision.allowed
}

// token_bucket_tokens returns how many whole tokens `b` holds right now.
token_bucket_tokens :: proc(b: ^Token_Bucket) -> int {
	if b.config.refill_interval <= 0 {
		return 0
	}
	token_bucket_refill(b, clock_now(b.clock))
	return to_int(b.level / i128(b.config.refill_interval))
}

@(private = "file")
token_bucket_full :: proc(b: ^Token_Bucket) -> i128 {
	return i128(b.config.capacity) * i128(b.config.refill_interval)
}

// token_bucket_refill credits the tokens earned since the last refill. A clock
// that moves backwards earns nothing until it passes the last reading again.
@(private = "file")
token_bucket_refill :: proc(b: ^Token_Bucket, now: time.Duration) {
	if now <= b.last {
		return
	}
	full := token_bucket_full(b)
	elapsed := i128(now - b.last)
	b.level = min(b.level + elapsed * i128(b.config.refill_amount), full)
	b.last = now
}
