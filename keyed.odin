package ratelimit

import "base:runtime"
import "core:strings"
import "core:time"

/*
Keyed_Config describes a Keyed_Limiter.

Fields:
- limiter: the configuration every per-key limiter is built from.
- max_keys: the most keys tracked at once; 0 means no limit.
- idle_timeout: how long a key may go unused before keyed_limiter_prune
  removes it; 0 means keys are only removed by hand.
*/
Keyed_Config :: struct {
	limiter:      Limiter_Config,
	max_keys:     int,
	idle_timeout: time.Duration,
}

/*
Keyed_Limiter keeps one Limiter per key, such as one per client address or
API token. It creates a limiter the first time it sees a key.

Its memory grows with the number of keys. Bound it with `max_keys`, and call
keyed_limiter_prune from time to time to drop idle keys.

Create one with keyed_limiter_init and free it with keyed_limiter_destroy.
A Keyed_Limiter is safe to use from one thread at a time; see
Sync_Keyed_Limiter for shared use.
*/
Keyed_Limiter :: struct {
	config:    Keyed_Config,
	clock:     Clock,
	entries:   map[string]Keyed_Entry,
	allocator: runtime.Allocator,
}

// Keyed_Entry is one key's limiter and the last time the key was used.
Keyed_Entry :: struct {
	limiter:   Limiter,
	last_used: time.Duration,
}

// keyed_config_validate reports whether `config` describes a usable keyed limiter.
keyed_config_validate :: proc(config: Keyed_Config) -> Error {
	if config.max_keys < 0 || config.idle_timeout < 0 {
		return .Invalid_Keyed_Config
	}
	return limiter_config_validate(config.limiter)
}

/*
keyed_limiter_init validates `config` and prepares `k`. The zero `clock`
means the system clock. Every later allocation, including key copies and
per-key limiters, uses `allocator`.

Returns:
- err: a Config_Error when `config` is invalid, in which case `k` is left
  untouched. Otherwise free `k` with keyed_limiter_destroy.
*/
keyed_limiter_init :: proc(
	k: ^Keyed_Limiter,
	config: Keyed_Config,
	clock := Clock{},
	allocator := context.allocator,
) -> (
	err: Error,
) {
	keyed_config_validate(config) or_return
	k^ = Keyed_Limiter {
		config    = config,
		clock     = clock,
		entries   = make(map[string]Keyed_Entry, allocator),
		allocator = allocator,
	}
	return nil
}

// keyed_limiter_destroy frees every key, every per-key limiter and the map, then zeroes `k`.
keyed_limiter_destroy :: proc(k: ^Keyed_Limiter) {
	for key, &entry in k.entries {
		limiter_destroy(&entry.limiter)
		delete(key, k.allocator)
	}
	delete(k.entries)
	k^ = {}
}

/*
keyed_limiter_take asks the limiter for `key` for `cost` units, creating it
on first use. `key` is copied, so the caller may free it after the call.

When the limiter is at `max_keys`, it first prunes idle keys. If that frees
no room, the request fails with `.Too_Many_Keys` and no key is added.

Returns:
- decision: the outcome for this key; see Decision.
- err: a Take_Error for a malformed request, `.Too_Many_Keys`, or an allocator error.
*/
keyed_limiter_take :: proc(k: ^Keyed_Limiter, key: string, cost := 1) -> (decision: Decision, err: Error) {
	if k.config.limiter == nil {
		return {}, .Not_Initialized
	}
	if cost < 1 {
		return {}, .Invalid_Cost
	}
	if cost > limiter_config_capacity(k.config.limiter) {
		return {}, .Cost_Exceeds_Capacity
	}
	now := clock_now(k.clock)
	entry, found := &k.entries[key]
	if !found {
		if k.config.max_keys > 0 && len(k.entries) >= k.config.max_keys {
			keyed_limiter_prune(k)
			if len(k.entries) >= k.config.max_keys {
				return {}, .Too_Many_Keys
			}
		}
		entry = keyed_limiter_insert(k, key) or_return
	}
	entry.last_used = now
	return limiter_take(&entry.limiter, cost)
}

// keyed_limiter_allow asks the limiter for `key` for one unit and reports whether it was granted.
keyed_limiter_allow :: proc(k: ^Keyed_Limiter, key: string) -> bool {
	decision, err := keyed_limiter_take(k, key, 1)
	return err == nil && decision.allowed
}

/*
keyed_limiter_remaining returns how many units the limiter for `key` would
grant right now. An unknown key reports what a fresh limiter would grant,
without creating one.
*/
keyed_limiter_remaining :: proc(k: ^Keyed_Limiter, key: string) -> int {
	if entry, found := &k.entries[key]; found {
		return limiter_remaining(&entry.limiter)
	}
	fresh: Limiter
	// A fresh limiter only allocates for a Sliding_Window_Log, and its
	// remaining count is the limit, so skip building one.
	if c, ok := k.config.limiter.(Sliding_Window_Log_Config); ok {
		return c.limit
	}
	if limiter_init(&fresh, k.config.limiter, k.clock) != nil {
		return 0
	}
	return limiter_remaining(&fresh)
}

// keyed_limiter_remove forgets `key` and reports whether it was present.
keyed_limiter_remove :: proc(k: ^Keyed_Limiter, key: string) -> bool {
	if key not_in k.entries {
		return false
	}
	owned, entry := delete_key(&k.entries, key)
	limiter_destroy(&entry.limiter)
	delete(owned, k.allocator)
	return true
}

/*
keyed_limiter_prune removes every key that has gone unused for at least
`idle_timeout` and returns how many it removed. It does nothing when
`idle_timeout` is 0. Its cost grows with the number of keys.
*/
keyed_limiter_prune :: proc(k: ^Keyed_Limiter) -> (removed: int) {
	if k.config.idle_timeout <= 0 || len(k.entries) == 0 {
		return 0
	}
	now := clock_now(k.clock)
	// Deleting while iterating a map is unsafe, so collect stale keys in
	// fixed batches. This keeps pruning allocation free.
	for {
		stale: [64]string
		n := 0
		for key, entry in k.entries {
			if now - entry.last_used >= k.config.idle_timeout {
				stale[n] = key
				n += 1
				if n == len(stale) {
					break
				}
			}
		}
		for key in stale[:n] {
			keyed_limiter_remove(k, key)
		}
		removed += n
		if n < len(stale) {
			return
		}
	}
}

// keyed_limiter_len returns how many keys `k` tracks.
keyed_limiter_len :: proc(k: ^Keyed_Limiter) -> int {
	return len(k.entries)
}

// keyed_limiter_contains reports whether `k` tracks `key`.
keyed_limiter_contains :: proc(k: ^Keyed_Limiter, key: string) -> bool {
	return key in k.entries
}

// keyed_limiter_clear removes every key but keeps the configuration.
keyed_limiter_clear :: proc(k: ^Keyed_Limiter) {
	for key, &entry in k.entries {
		limiter_destroy(&entry.limiter)
		delete(key, k.allocator)
	}
	clear(&k.entries)
}

@(private = "file")
keyed_limiter_insert :: proc(k: ^Keyed_Limiter, key: string) -> (entry: ^Keyed_Entry, err: Error) {
	limiter: Limiter
	limiter_init(&limiter, k.config.limiter, k.clock, k.allocator) or_return
	owned, clone_err := strings.clone(key, k.allocator)
	if clone_err != nil {
		limiter_destroy(&limiter)
		return nil, clone_err
	}
	_, value, _, insert_err := map_entry(&k.entries, owned)
	if insert_err != nil {
		limiter_destroy(&limiter)
		delete(owned, k.allocator)
		return nil, insert_err
	}
	value^ = Keyed_Entry{limiter = limiter}
	return value, nil
}
