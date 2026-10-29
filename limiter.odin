package ratelimit

/*
Limiter_Config selects an algorithm and its settings. A Sliding_Window_Log
and a Sliding_Window_Counter share Sliding_Window_Config, so this union wraps
them in distinct types.
*/
Limiter_Config :: union {
	Token_Bucket_Config,
	Leaky_Bucket_Config,
	Sliding_Window_Log_Config,
	Sliding_Window_Counter_Config,
}

// Sliding_Window_Log_Config selects a Sliding_Window_Log in a Limiter_Config.
Sliding_Window_Log_Config :: distinct Sliding_Window_Config

// Sliding_Window_Counter_Config selects a Sliding_Window_Counter in a Limiter_Config.
Sliding_Window_Counter_Config :: distinct Sliding_Window_Config

/*
Limiter holds any one of the limiters in this package behind a single API,
so code such as the Keyed_Limiter can stay independent of the algorithm.

Create one with limiter_init and free it with limiter_destroy. A Limiter is
safe to use from one thread at a time; see Sync_Limiter for shared use.
*/
Limiter :: union {
	Token_Bucket,
	Leaky_Bucket,
	Sliding_Window_Log,
	Sliding_Window_Counter,
}

// limiter_config_validate reports whether `config` describes a usable limiter.
limiter_config_validate :: proc(config: Limiter_Config) -> Error {
	switch c in config {
	case Token_Bucket_Config:
		return token_bucket_config_validate(c)
	case Leaky_Bucket_Config:
		return leaky_bucket_config_validate(c)
	case Sliding_Window_Log_Config:
		return sliding_window_config_validate(Sliding_Window_Config(c))
	case Sliding_Window_Counter_Config:
		return sliding_window_config_validate(Sliding_Window_Config(c))
	case:
		return .Missing_Config
	}
}

/*
limiter_init builds the limiter that `config` selects. The zero `clock` means
the system clock. Only a Sliding_Window_Log uses `allocator`.

Returns:
- err: a Config_Error when `config` is invalid, or an allocator error. On
  error `l` is nil. Otherwise free it with limiter_destroy.
*/
limiter_init :: proc(
	l: ^Limiter,
	config: Limiter_Config,
	clock := Clock{},
	allocator := context.allocator,
) -> (
	err: Error,
) {
	l^ = nil
	switch c in config {
	case Token_Bucket_Config:
		b: Token_Bucket
		token_bucket_init(&b, c, clock) or_return
		l^ = b
	case Leaky_Bucket_Config:
		b: Leaky_Bucket
		leaky_bucket_init(&b, c, clock) or_return
		l^ = b
	case Sliding_Window_Log_Config:
		w: Sliding_Window_Log
		sliding_window_log_init(&w, Sliding_Window_Config(c), clock, allocator) or_return
		l^ = w
	case Sliding_Window_Counter_Config:
		w: Sliding_Window_Counter
		sliding_window_counter_init(&w, Sliding_Window_Config(c), clock) or_return
		l^ = w
	case:
		return .Missing_Config
	}
	return nil
}

// limiter_destroy frees any memory `l` owns and sets it to nil.
limiter_destroy :: proc(l: ^Limiter) {
	if w, ok := &l.(Sliding_Window_Log); ok {
		sliding_window_log_destroy(w)
	}
	l^ = nil
}

/*
limiter_take asks `l` for `cost` units.

Returns:
- decision: the outcome; see Decision.
- err: a Take_Error for a malformed request, or `.Not_Initialized` when `l` is nil.
*/
limiter_take :: proc(l: ^Limiter, cost := 1) -> (decision: Decision, err: Error) {
	switch &v in l {
	case Token_Bucket:
		return token_bucket_take(&v, cost)
	case Leaky_Bucket:
		return leaky_bucket_take(&v, cost)
	case Sliding_Window_Log:
		return sliding_window_log_take(&v, cost)
	case Sliding_Window_Counter:
		return sliding_window_counter_take(&v, cost)
	case:
		return {}, .Not_Initialized
	}
}

// limiter_allow asks `l` for one unit and reports whether it was granted.
limiter_allow :: proc(l: ^Limiter) -> bool {
	decision, err := limiter_take(l, 1)
	return err == nil && decision.allowed
}

// limiter_remaining returns how many units `l` would grant right now, or 0 when nil.
limiter_remaining :: proc(l: ^Limiter) -> int {
	switch &v in l {
	case Token_Bucket:
		return token_bucket_tokens(&v)
	case Leaky_Bucket:
		return leaky_bucket_remaining(&v)
	case Sliding_Window_Log:
		return sliding_window_log_remaining(&v)
	case Sliding_Window_Counter:
		return sliding_window_counter_remaining(&v)
	case:
		return 0
	}
}

// limiter_reset returns `l` to the state it had right after limiter_init.
limiter_reset :: proc(l: ^Limiter) {
	switch &v in l {
	case Token_Bucket:
		token_bucket_reset(&v)
	case Leaky_Bucket:
		leaky_bucket_reset(&v)
	case Sliding_Window_Log:
		sliding_window_log_reset(&v)
	case Sliding_Window_Counter:
		sliding_window_counter_reset(&v)
	}
}

// limiter_config_capacity returns the largest cost a limiter built from `config` can grant at once.
@(private)
limiter_config_capacity :: proc(config: Limiter_Config) -> int {
	switch c in config {
	case Token_Bucket_Config:
		return c.capacity
	case Leaky_Bucket_Config:
		return c.capacity
	case Sliding_Window_Log_Config:
		return c.limit
	case Sliding_Window_Counter_Config:
		return c.limit
	}
	return 0
}
