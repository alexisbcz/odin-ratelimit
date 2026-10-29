package ratelimit

import "core:time"

/*
Leaky_Bucket_Config describes a leaky bucket used as a queue.

Fields:
- capacity: the most units the bucket queues at once; at least 1.
- leak_amount: how many units drain every `leak_interval`; at least 1.
- leak_interval: the period of `leak_amount`; must be positive.
*/
Leaky_Bucket_Config :: struct {
	capacity:      int,
	leak_amount:   int,
	leak_interval: time.Duration,
}

/*
Leaky_Bucket smooths traffic into a constant output rate. Each granted
request joins a queue that drains at `leak_amount / leak_interval`. The
Decision's `delay` field says how long the caller should wait before acting,
which is the time until everything queued ahead of it has drained. A request
that would overflow the queue is denied.

Use a Token_Bucket to allow bursts, and a Leaky_Bucket to spread work out
evenly. A Leaky_Bucket allocates nothing and is safe to use from one thread
at a time.
*/
Leaky_Bucket :: struct {
	config: Leaky_Bucket_Config,
	clock:  Clock,
	// Queued units scaled by leak_interval.
	level:  i128,
	last:   time.Duration,
}

// leaky_bucket_config_validate reports whether `config` describes a usable bucket.
leaky_bucket_config_validate :: proc(config: Leaky_Bucket_Config) -> Error {
	if config.capacity < 1 {
		return .Invalid_Capacity
	}
	if config.leak_amount < 1 {
		return .Invalid_Amount
	}
	if config.leak_interval <= 0 {
		return .Invalid_Interval
	}
	return nil
}

/*
leaky_bucket_init validates `config` and prepares an empty bucket. The zero
`clock` means the system clock.

Returns:
- err: a Config_Error when `config` is invalid, in which case `b` is left untouched.
*/
leaky_bucket_init :: proc(b: ^Leaky_Bucket, config: Leaky_Bucket_Config, clock := Clock{}) -> (err: Error) {
	leaky_bucket_config_validate(config) or_return
	b.config = config
	b.clock = clock
	leaky_bucket_reset(b)
	return nil
}

// leaky_bucket_reset empties `b` as of the current time.
leaky_bucket_reset :: proc(b: ^Leaky_Bucket) {
	b.last = clock_now(b.clock)
	b.level = 0
}

/*
leaky_bucket_take tries to queue `cost` units in `b`.

Returns:
- decision: when allowed, `delay` is how long to wait before acting; when
  denied, `retry_after` is how long until the queue has room.
- err: `.Invalid_Cost` when `cost < 1`, `.Cost_Exceeds_Capacity` when `cost` is
  larger than the capacity, or `.Not_Initialized`. On error nothing changes.
*/
leaky_bucket_take :: proc(b: ^Leaky_Bucket, cost := 1) -> (decision: Decision, err: Error) {
	if b.config.leak_interval <= 0 {
		return {}, .Not_Initialized
	}
	if cost < 1 {
		return {}, .Invalid_Cost
	}
	if cost > b.config.capacity {
		return {}, .Cost_Exceeds_Capacity
	}
	leaky_bucket_drain(b, clock_now(b.clock))

	interval := i128(b.config.leak_interval)
	amount := i128(b.config.leak_amount)
	full := i128(b.config.capacity) * interval
	add := i128(cost) * interval
	if b.level + add <= full {
		decision.delay = to_duration(ceil_div(b.level, amount))
		b.level += add
		decision.allowed = true
	} else {
		decision.retry_after = to_duration(ceil_div(b.level + add - full, amount))
	}
	decision.remaining = to_int((full - b.level) / interval)
	decision.reset_after = to_duration(ceil_div(b.level, amount))
	return
}

// leaky_bucket_allow queues one unit and reports whether it fit.
leaky_bucket_allow :: proc(b: ^Leaky_Bucket) -> bool {
	decision, err := leaky_bucket_take(b, 1)
	return err == nil && decision.allowed
}

// leaky_bucket_level returns how many units are queued right now, rounded up.
leaky_bucket_level :: proc(b: ^Leaky_Bucket) -> int {
	if b.config.leak_interval <= 0 {
		return 0
	}
	leaky_bucket_drain(b, clock_now(b.clock))
	return to_int(ceil_div(b.level, i128(b.config.leak_interval)))
}

// leaky_bucket_remaining returns how many units fit in the queue right now.
leaky_bucket_remaining :: proc(b: ^Leaky_Bucket) -> int {
	if b.config.leak_interval <= 0 {
		return 0
	}
	leaky_bucket_drain(b, clock_now(b.clock))
	interval := i128(b.config.leak_interval)
	return to_int((i128(b.config.capacity) * interval - b.level) / interval)
}

@(private = "file")
leaky_bucket_drain :: proc(b: ^Leaky_Bucket, now: time.Duration) {
	if now <= b.last {
		return
	}
	elapsed := i128(now - b.last)
	b.level = max(b.level - elapsed * i128(b.config.leak_amount), 0)
	b.last = now
}
