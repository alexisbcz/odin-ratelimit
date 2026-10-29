package ratelimit

import "base:runtime"
import "core:time"

/*
Sliding_Window_Config describes a sliding window limit: at most `limit`
units in any span of `window`.

Fields:
- limit: the most units granted per window; at least 1.
- window: the window length; must be positive.
*/
Sliding_Window_Config :: struct {
	limit:  int,
	window: time.Duration,
}

// sliding_window_config_validate reports whether `config` describes a usable window.
sliding_window_config_validate :: proc(config: Sliding_Window_Config) -> Error {
	if config.limit < 1 {
		return .Invalid_Limit
	}
	if config.window <= 0 {
		return .Invalid_Window
	}
	return nil
}

/*
Sliding_Window_Log enforces an exact sliding window by remembering the time
of every granted unit. It never lets more than `limit` units through in any
`window`, at the cost of `limit` timestamps of memory.

Create one with sliding_window_log_init and free it with
sliding_window_log_destroy. A Sliding_Window_Log is safe to use from one
thread at a time.
*/
Sliding_Window_Log :: struct {
	config:    Sliding_Window_Config,
	clock:     Clock,
	// Ring buffer of grant times, oldest at `head`.
	entries:   []time.Duration,
	head:      int,
	count:     int,
	allocator: runtime.Allocator,
}

/*
sliding_window_log_init validates `config` and allocates room for `limit`
timestamps. The zero `clock` means the system clock.

Returns:
- err: a Config_Error when `config` is invalid, or an allocator error. On
  error `l` holds no memory. Otherwise free it with sliding_window_log_destroy.
*/
sliding_window_log_init :: proc(
	l: ^Sliding_Window_Log,
	config: Sliding_Window_Config,
	clock := Clock{},
	allocator := context.allocator,
) -> (
	err: Error,
) {
	sliding_window_config_validate(config) or_return
	entries := make([]time.Duration, config.limit, allocator) or_return
	l^ = Sliding_Window_Log {
		config    = config,
		clock     = clock,
		entries   = entries,
		allocator = allocator,
	}
	return nil
}

// sliding_window_log_destroy frees the timestamps of `l` and zeroes it.
sliding_window_log_destroy :: proc(l: ^Sliding_Window_Log) {
	delete(l.entries, l.allocator)
	l^ = {}
}

// sliding_window_log_reset forgets every recorded grant.
sliding_window_log_reset :: proc(l: ^Sliding_Window_Log) {
	l.head = 0
	l.count = 0
}

/*
sliding_window_log_take tries to record `cost` units at the current time.

Returns:
- decision: when denied, `retry_after` is the exact time until enough old
  grants leave the window.
- err: `.Invalid_Cost` when `cost < 1`, `.Cost_Exceeds_Capacity` when `cost` is
  larger than the limit, or `.Not_Initialized`. On error nothing changes.
*/
sliding_window_log_take :: proc(l: ^Sliding_Window_Log, cost := 1) -> (decision: Decision, err: Error) {
	if len(l.entries) == 0 {
		return {}, .Not_Initialized
	}
	if cost < 1 {
		return {}, .Invalid_Cost
	}
	if cost > l.config.limit {
		return {}, .Cost_Exceeds_Capacity
	}
	now := clock_now(l.clock)
	sliding_window_log_evict(l, now)

	limit := l.config.limit
	if l.count + cost <= limit {
		for _ in 0 ..< cost {
			l.entries[(l.head + l.count) % limit] = now
			l.count += 1
		}
		decision.allowed = true
	} else {
		// The request fits once the oldest `count + cost - limit` grants expire.
		last_to_expire := l.entries[(l.head + l.count + cost - limit - 1) % limit]
		decision.retry_after = to_duration(i128(last_to_expire) + i128(l.config.window) - i128(now))
	}
	decision.remaining = limit - l.count
	if l.count > 0 {
		newest := l.entries[(l.head + l.count - 1) % limit]
		decision.reset_after = to_duration(i128(newest) + i128(l.config.window) - i128(now))
	}
	return
}

// sliding_window_log_allow records one unit and reports whether it fit.
sliding_window_log_allow :: proc(l: ^Sliding_Window_Log) -> bool {
	decision, err := sliding_window_log_take(l, 1)
	return err == nil && decision.allowed
}

// sliding_window_log_remaining returns how many units the window grants right now.
sliding_window_log_remaining :: proc(l: ^Sliding_Window_Log) -> int {
	if len(l.entries) == 0 {
		return 0
	}
	sliding_window_log_evict(l, clock_now(l.clock))
	return l.config.limit - l.count
}

@(private = "file")
sliding_window_log_evict :: proc(l: ^Sliding_Window_Log, now: time.Duration) {
	for l.count > 0 && i128(l.entries[l.head]) + i128(l.config.window) <= i128(now) {
		l.head = (l.head + 1) % l.config.limit
		l.count -= 1
	}
}

/*
Sliding_Window_Counter approximates a sliding window with two fixed-window
counters. It weights the previous window's count by how much of it still
overlaps the sliding window. It needs constant memory, but its count is an
estimate that assumes the previous window's grants were spread evenly.

It allocates nothing and is safe to use from one thread at a time.
*/
Sliding_Window_Counter :: struct {
	config:       Sliding_Window_Config,
	clock:        Clock,
	window_start: time.Duration,
	previous:     int,
	current:      int,
}

/*
sliding_window_counter_init validates `config` and starts the first window at
the current time. The zero `clock` means the system clock.

Returns:
- err: a Config_Error when `config` is invalid, in which case `c` is left untouched.
*/
sliding_window_counter_init :: proc(
	c: ^Sliding_Window_Counter,
	config: Sliding_Window_Config,
	clock := Clock{},
) -> (
	err: Error,
) {
	sliding_window_config_validate(config) or_return
	c.config = config
	c.clock = clock
	sliding_window_counter_reset(c)
	return nil
}

// sliding_window_counter_reset clears both counters and starts a new window now.
sliding_window_counter_reset :: proc(c: ^Sliding_Window_Counter) {
	c.window_start = clock_now(c.clock)
	c.previous = 0
	c.current = 0
}

/*
sliding_window_counter_take tries to record `cost` units at the current time.

Returns:
- decision: when denied, `retry_after` is how long until the weighted count
  leaves room for `cost`.
- err: `.Invalid_Cost` when `cost < 1`, `.Cost_Exceeds_Capacity` when `cost` is
  larger than the limit, or `.Not_Initialized`. On error nothing changes.
*/
sliding_window_counter_take :: proc(c: ^Sliding_Window_Counter, cost := 1) -> (decision: Decision, err: Error) {
	if c.config.window <= 0 {
		return {}, .Not_Initialized
	}
	if cost < 1 {
		return {}, .Invalid_Cost
	}
	if cost > c.config.limit {
		return {}, .Cost_Exceeds_Capacity
	}
	elapsed := sliding_window_counter_advance(c, clock_now(c.clock))
	window := i128(c.config.window)
	limit := c.config.limit

	room := i128(limit - cost - c.current)
	if room >= 0 && i128(c.previous) * (window - elapsed) <= room * window {
		c.current += cost
		decision.allowed = true
	} else if room >= 0 {
		decision.retry_after = to_duration(counter_wait(i128(c.previous), room, window) - elapsed)
	} else {
		// Wait for the next window, where `current` becomes the weighted part.
		next_room := i128(limit - cost)
		decision.retry_after = to_duration(window - elapsed + counter_wait(i128(c.current), next_room, window))
	}
	used := ceil_div(i128(c.previous) * (window - elapsed), window) + i128(c.current)
	decision.remaining = to_int(i128(limit) - used)
	if c.current > 0 {
		decision.reset_after = to_duration(2 * window - elapsed)
	} else if c.previous > 0 {
		decision.reset_after = to_duration(window - elapsed)
	}
	return
}

// sliding_window_counter_allow records one unit and reports whether it fit.
sliding_window_counter_allow :: proc(c: ^Sliding_Window_Counter) -> bool {
	decision, err := sliding_window_counter_take(c, 1)
	return err == nil && decision.allowed
}

// sliding_window_counter_remaining returns how many units the window grants right now.
sliding_window_counter_remaining :: proc(c: ^Sliding_Window_Counter) -> int {
	if c.config.window <= 0 {
		return 0
	}
	elapsed := sliding_window_counter_advance(c, clock_now(c.clock))
	window := i128(c.config.window)
	used := ceil_div(i128(c.previous) * (window - elapsed), window) + i128(c.current)
	return to_int(i128(c.config.limit) - used)
}

// sliding_window_counter_advance rolls the windows forward to `now` and
// returns how far into the current window `now` is.
@(private = "file")
sliding_window_counter_advance :: proc(c: ^Sliding_Window_Counter, now: time.Duration) -> i128 {
	if now <= c.window_start {
		return 0
	}
	window := i128(c.config.window)
	since := i128(now - c.window_start)
	periods := since / window
	if periods == 1 {
		c.previous = c.current
		c.current = 0
	} else if periods >= 2 {
		c.previous = 0
		c.current = 0
	}
	c.window_start = time.Duration(i128(c.window_start) + periods * window)
	return since - periods * window
}

// counter_wait returns how far into a window the weighted `previous` count
// must decay before it fits in `room`.
@(private = "file")
counter_wait :: proc "contextless" (previous, room, window: i128) -> i128 {
	if previous <= room {
		return 0
	}
	return ceil_div(window * (previous - room), previous)
}
