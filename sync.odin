package ratelimit

import "core:sync"

/*
Sync_Limiter is a Limiter guarded by a mutex, so any number of threads may
call its procedures at once. Every call takes the lock for its whole
duration, which keeps each decision atomic.

Create one with sync_limiter_init and free it with sync_limiter_destroy
after every thread has stopped using it. Don't copy a Sync_Limiter once it
is in use.
*/
Sync_Limiter :: struct {
	mutex:   sync.Mutex,
	limiter: Limiter,
}

/*
sync_limiter_init builds the limiter that `config` selects. See limiter_init.
The clock must also be safe to read from several threads; the system clock
and Manual_Clock both are.

Returns:
- err: a Config_Error when `config` is invalid, or an allocator error.
*/
sync_limiter_init :: proc(
	l: ^Sync_Limiter,
	config: Limiter_Config,
	clock := Clock{},
	allocator := context.allocator,
) -> (
	err: Error,
) {
	return limiter_init(&l.limiter, config, clock, allocator)
}

// sync_limiter_destroy frees the inner limiter. No other thread may use `l` during or after the call.
sync_limiter_destroy :: proc(l: ^Sync_Limiter) {
	limiter_destroy(&l.limiter)
	l^ = {}
}

// sync_limiter_take asks for `cost` units under the lock. See limiter_take.
sync_limiter_take :: proc(l: ^Sync_Limiter, cost := 1) -> (decision: Decision, err: Error) {
	sync.mutex_guard(&l.mutex)
	return limiter_take(&l.limiter, cost)
}

// sync_limiter_allow asks for one unit under the lock and reports whether it was granted.
sync_limiter_allow :: proc(l: ^Sync_Limiter) -> bool {
	sync.mutex_guard(&l.mutex)
	return limiter_allow(&l.limiter)
}

// sync_limiter_remaining returns how many units the limiter would grant right now.
sync_limiter_remaining :: proc(l: ^Sync_Limiter) -> int {
	sync.mutex_guard(&l.mutex)
	return limiter_remaining(&l.limiter)
}

// sync_limiter_reset returns the limiter to its starting state under the lock.
sync_limiter_reset :: proc(l: ^Sync_Limiter) {
	sync.mutex_guard(&l.mutex)
	limiter_reset(&l.limiter)
}

/*
Sync_Keyed_Limiter is a Keyed_Limiter guarded by a mutex, so any number of
threads may call its procedures at once.

Create one with sync_keyed_limiter_init and free it with
sync_keyed_limiter_destroy after every thread has stopped using it. Don't
copy a Sync_Keyed_Limiter once it is in use.
*/
Sync_Keyed_Limiter :: struct {
	mutex: sync.Mutex,
	keyed: Keyed_Limiter,
}

/*
sync_keyed_limiter_init validates `config` and prepares `k`. See
keyed_limiter_init. The allocator must be safe to call from whichever thread
holds the lock; the default heap allocator is.

Returns:
- err: a Config_Error when `config` is invalid.
*/
sync_keyed_limiter_init :: proc(
	k: ^Sync_Keyed_Limiter,
	config: Keyed_Config,
	clock := Clock{},
	allocator := context.allocator,
) -> (
	err: Error,
) {
	return keyed_limiter_init(&k.keyed, config, clock, allocator)
}

// sync_keyed_limiter_destroy frees every key and limiter. No other thread may use `k` during or after the call.
sync_keyed_limiter_destroy :: proc(k: ^Sync_Keyed_Limiter) {
	keyed_limiter_destroy(&k.keyed)
	k^ = {}
}

// sync_keyed_limiter_take asks the limiter for `key` for `cost` units under the lock. See keyed_limiter_take.
sync_keyed_limiter_take :: proc(k: ^Sync_Keyed_Limiter, key: string, cost := 1) -> (decision: Decision, err: Error) {
	sync.mutex_guard(&k.mutex)
	return keyed_limiter_take(&k.keyed, key, cost)
}

// sync_keyed_limiter_allow asks the limiter for `key` for one unit and reports whether it was granted.
sync_keyed_limiter_allow :: proc(k: ^Sync_Keyed_Limiter, key: string) -> bool {
	sync.mutex_guard(&k.mutex)
	return keyed_limiter_allow(&k.keyed, key)
}

// sync_keyed_limiter_remaining returns how many units the limiter for `key` would grant right now.
sync_keyed_limiter_remaining :: proc(k: ^Sync_Keyed_Limiter, key: string) -> int {
	sync.mutex_guard(&k.mutex)
	return keyed_limiter_remaining(&k.keyed, key)
}

// sync_keyed_limiter_remove forgets `key` under the lock and reports whether it was present.
sync_keyed_limiter_remove :: proc(k: ^Sync_Keyed_Limiter, key: string) -> bool {
	sync.mutex_guard(&k.mutex)
	return keyed_limiter_remove(&k.keyed, key)
}

// sync_keyed_limiter_prune removes idle keys under the lock and returns how many it removed.
sync_keyed_limiter_prune :: proc(k: ^Sync_Keyed_Limiter) -> int {
	sync.mutex_guard(&k.mutex)
	return keyed_limiter_prune(&k.keyed)
}

// sync_keyed_limiter_len returns how many keys are tracked.
sync_keyed_limiter_len :: proc(k: ^Sync_Keyed_Limiter) -> int {
	sync.mutex_guard(&k.mutex)
	return keyed_limiter_len(&k.keyed)
}

// sync_keyed_limiter_contains reports whether `key` is tracked.
sync_keyed_limiter_contains :: proc(k: ^Sync_Keyed_Limiter, key: string) -> bool {
	sync.mutex_guard(&k.mutex)
	return keyed_limiter_contains(&k.keyed, key)
}

// sync_keyed_limiter_clear removes every key under the lock but keeps the configuration.
sync_keyed_limiter_clear :: proc(k: ^Sync_Keyed_Limiter) {
	sync.mutex_guard(&k.mutex)
	keyed_limiter_clear(&k.keyed)
}
