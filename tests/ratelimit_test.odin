// Package ratelimit_tests holds the unit tests for ratelimit. Run them with `odin test tests`.
package ratelimit_tests

import ratelimit ".."
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

MS :: time.Millisecond
SEC :: time.Second

// track_begin wraps the context allocator in a tracking allocator.
track_begin :: proc(track: ^mem.Tracking_Allocator) -> runtime.Allocator {
	mem.tracking_allocator_init(track, context.allocator)
	return mem.tracking_allocator(track)
}

// track_end fails the test on any leak or bad free, then frees the tracker.
track_end :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator) {
	for _, leak in track.allocation_map {
		testing.expectf(t, false, "leaked %v bytes at %v", leak.size, leak.location)
	}
	for bad in track.bad_free_array {
		testing.expectf(t, false, "bad free at %v", bad.location)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
	mem.tracking_allocator_destroy(track)
}

err_of :: proc(e: $E) -> ratelimit.Error {
	return ratelimit.Error(e)
}

// ---------------------------------------------------------------------------
// Clocks
// ---------------------------------------------------------------------------

@(test)
test_manual_clock_advance_and_set :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	clock := ratelimit.manual_clock(&c)
	testing.expect_value(t, ratelimit.clock_now(clock), 0)
	ratelimit.manual_clock_advance(&c, 5 * MS)
	testing.expect_value(t, ratelimit.clock_now(clock), 5 * MS)
	ratelimit.manual_clock_set(&c, SEC)
	testing.expect_value(t, ratelimit.manual_clock_now(&c), SEC)
	ratelimit.manual_clock_advance(&c, -SEC)
	testing.expect_value(t, ratelimit.manual_clock_now(&c), 0)
}

@(test)
test_zero_clock_uses_monotonic_system_clock :: proc(t: ^testing.T) {
	a := ratelimit.clock_now({})
	b := ratelimit.clock_now(ratelimit.system_clock())
	testing.expect(t, b >= a, "system clock went backwards")
}

// ---------------------------------------------------------------------------
// Token bucket
// ---------------------------------------------------------------------------

@(test)
test_token_bucket_starts_full_and_drains :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Token_Bucket
	err := ratelimit.token_bucket_init(&b, {capacity = 3, refill_amount = 1, refill_interval = SEC}, ratelimit.manual_clock(&c))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 3)
	for _ in 0 ..< 3 {
		testing.expect(t, ratelimit.token_bucket_allow(&b))
	}
	testing.expect(t, !ratelimit.token_bucket_allow(&b))
}

@(test)
test_token_bucket_refills_continuously :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Token_Bucket
	_ = ratelimit.token_bucket_init(&b, {capacity = 10, refill_amount = 10, refill_interval = SEC, start_empty = true}, ratelimit.manual_clock(&c))
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 0)
	ratelimit.manual_clock_advance(&c, 99 * MS)
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 0)
	ratelimit.manual_clock_advance(&c, 1 * MS)
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 1)
	ratelimit.manual_clock_advance(&c, 450 * MS)
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 5)
}

@(test)
test_token_bucket_never_exceeds_capacity :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Token_Bucket
	_ = ratelimit.token_bucket_init(&b, {capacity = 4, refill_amount = 1, refill_interval = MS}, ratelimit.manual_clock(&c))
	ratelimit.manual_clock_advance(&c, 1000 * SEC)
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 4)
}

@(test)
test_token_bucket_retry_after_is_exact :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Token_Bucket
	_ = ratelimit.token_bucket_init(&b, {capacity = 2, refill_amount = 1, refill_interval = SEC}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.token_bucket_take(&b, 2)
	ratelimit.manual_clock_advance(&c, 300 * MS)
	d, err := ratelimit.token_bucket_take(&b, 1)
	testing.expect_value(t, err, nil)
	testing.expect(t, !d.allowed)
	testing.expect_value(t, d.retry_after, 700 * MS)
	ratelimit.manual_clock_advance(&c, d.retry_after - 1)
	testing.expect(t, !ratelimit.token_bucket_allow(&b))
	ratelimit.manual_clock_advance(&c, 1)
	testing.expect(t, ratelimit.token_bucket_allow(&b))
}

@(test)
test_token_bucket_take_reports_remaining_and_reset :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Token_Bucket
	_ = ratelimit.token_bucket_init(&b, {capacity = 5, refill_amount = 1, refill_interval = SEC}, ratelimit.manual_clock(&c))
	d, err := ratelimit.token_bucket_take(&b, 2)
	testing.expect_value(t, err, nil)
	testing.expect(t, d.allowed)
	testing.expect_value(t, d.remaining, 3)
	testing.expect_value(t, d.retry_after, 0)
	testing.expect_value(t, d.reset_after, 2 * SEC)
	testing.expect_value(t, d.delay, 0)
}

@(test)
test_token_bucket_denied_take_keeps_tokens :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Token_Bucket
	_ = ratelimit.token_bucket_init(&b, {capacity = 5, refill_amount = 1, refill_interval = SEC}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.token_bucket_take(&b, 3)
	d, _ := ratelimit.token_bucket_take(&b, 3)
	testing.expect(t, !d.allowed)
	testing.expect_value(t, d.remaining, 2)
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 2)
}

@(test)
test_token_bucket_rejects_bad_costs :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Token_Bucket
	_ = ratelimit.token_bucket_init(&b, {capacity = 5, refill_amount = 1, refill_interval = SEC}, ratelimit.manual_clock(&c))
	_, err := ratelimit.token_bucket_take(&b, 0)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Invalid_Cost))
	_, err = ratelimit.token_bucket_take(&b, -3)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Invalid_Cost))
	_, err = ratelimit.token_bucket_take(&b, 6)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Cost_Exceeds_Capacity))
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 5)
}

@(test)
test_token_bucket_rejects_bad_config :: proc(t: ^testing.T) {
	b: ratelimit.Token_Bucket
	testing.expect_value(t, ratelimit.token_bucket_init(&b, {capacity = 0, refill_amount = 1, refill_interval = SEC}), err_of(ratelimit.Config_Error.Invalid_Capacity))
	testing.expect_value(t, ratelimit.token_bucket_init(&b, {capacity = 1, refill_amount = 0, refill_interval = SEC}), err_of(ratelimit.Config_Error.Invalid_Amount))
	testing.expect_value(t, ratelimit.token_bucket_init(&b, {capacity = 1, refill_amount = 1, refill_interval = 0}), err_of(ratelimit.Config_Error.Invalid_Interval))
	testing.expect_value(t, ratelimit.token_bucket_init(&b, {capacity = 1, refill_amount = 1, refill_interval = -SEC}), err_of(ratelimit.Config_Error.Invalid_Interval))
}

@(test)
test_token_bucket_zero_value_is_not_initialized :: proc(t: ^testing.T) {
	b: ratelimit.Token_Bucket
	_, err := ratelimit.token_bucket_take(&b)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Not_Initialized))
	testing.expect(t, !ratelimit.token_bucket_allow(&b))
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 0)
}

@(test)
test_token_bucket_ignores_clock_going_backwards :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	ratelimit.manual_clock_set(&c, 10 * SEC)
	b: ratelimit.Token_Bucket
	_ = ratelimit.token_bucket_init(&b, {capacity = 2, refill_amount = 1, refill_interval = SEC}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.token_bucket_take(&b, 2)
	ratelimit.manual_clock_set(&c, 5 * SEC)
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 0)
	ratelimit.manual_clock_set(&c, 11 * SEC)
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 1)
}

@(test)
test_token_bucket_reset_refills :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Token_Bucket
	_ = ratelimit.token_bucket_init(&b, {capacity = 3, refill_amount = 1, refill_interval = SEC}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.token_bucket_take(&b, 3)
	ratelimit.token_bucket_reset(&b)
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), 3)
}

@(test)
test_token_bucket_handles_huge_elapsed_time :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Token_Bucket
	_ = ratelimit.token_bucket_init(&b, {capacity = max(int) / 2, refill_amount = max(int) / 2, refill_interval = 1}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.token_bucket_take(&b, max(int) / 2)
	ratelimit.manual_clock_set(&c, time.Duration(max(i64)))
	testing.expect_value(t, ratelimit.token_bucket_tokens(&b), max(int) / 2)
}

// ---------------------------------------------------------------------------
// Leaky bucket
// ---------------------------------------------------------------------------

@(test)
test_leaky_bucket_spaces_requests_with_delay :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Leaky_Bucket
	err := ratelimit.leaky_bucket_init(&b, {capacity = 3, leak_amount = 1, leak_interval = 100 * MS}, ratelimit.manual_clock(&c))
	testing.expect_value(t, err, nil)
	expected := [3]time.Duration{0, 100 * MS, 200 * MS}
	for want in expected {
		d, take_err := ratelimit.leaky_bucket_take(&b)
		testing.expect_value(t, take_err, nil)
		testing.expect(t, d.allowed)
		testing.expect_value(t, d.delay, want)
	}
}

@(test)
test_leaky_bucket_denies_when_full :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Leaky_Bucket
	_ = ratelimit.leaky_bucket_init(&b, {capacity = 2, leak_amount = 1, leak_interval = 100 * MS}, ratelimit.manual_clock(&c))
	testing.expect(t, ratelimit.leaky_bucket_allow(&b))
	testing.expect(t, ratelimit.leaky_bucket_allow(&b))
	d, _ := ratelimit.leaky_bucket_take(&b)
	testing.expect(t, !d.allowed)
	testing.expect_value(t, d.retry_after, 100 * MS)
	testing.expect_value(t, d.remaining, 0)
	testing.expect_value(t, d.reset_after, 200 * MS)
}

@(test)
test_leaky_bucket_drains_over_time :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Leaky_Bucket
	_ = ratelimit.leaky_bucket_init(&b, {capacity = 4, leak_amount = 2, leak_interval = SEC}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.leaky_bucket_take(&b, 4)
	testing.expect_value(t, ratelimit.leaky_bucket_level(&b), 4)
	ratelimit.manual_clock_advance(&c, 500 * MS)
	testing.expect_value(t, ratelimit.leaky_bucket_level(&b), 3)
	testing.expect_value(t, ratelimit.leaky_bucket_remaining(&b), 1)
	ratelimit.manual_clock_advance(&c, 10 * SEC)
	testing.expect_value(t, ratelimit.leaky_bucket_level(&b), 0)
	testing.expect_value(t, ratelimit.leaky_bucket_remaining(&b), 4)
}

@(test)
test_leaky_bucket_retry_after_then_succeeds :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Leaky_Bucket
	_ = ratelimit.leaky_bucket_init(&b, {capacity = 3, leak_amount = 1, leak_interval = 30 * MS}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.leaky_bucket_take(&b, 3)
	d, _ := ratelimit.leaky_bucket_take(&b, 2)
	testing.expect(t, !d.allowed)
	testing.expect_value(t, d.retry_after, 60 * MS)
	ratelimit.manual_clock_advance(&c, d.retry_after)
	d, _ = ratelimit.leaky_bucket_take(&b, 2)
	testing.expect(t, d.allowed)
	testing.expect_value(t, d.delay, 30 * MS)
}

@(test)
test_leaky_bucket_rejects_bad_input :: proc(t: ^testing.T) {
	b: ratelimit.Leaky_Bucket
	_, err := ratelimit.leaky_bucket_take(&b)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Not_Initialized))
	testing.expect_value(t, ratelimit.leaky_bucket_level(&b), 0)
	testing.expect_value(t, ratelimit.leaky_bucket_remaining(&b), 0)
	testing.expect_value(t, ratelimit.leaky_bucket_init(&b, {capacity = 0, leak_amount = 1, leak_interval = SEC}), err_of(ratelimit.Config_Error.Invalid_Capacity))
	testing.expect_value(t, ratelimit.leaky_bucket_init(&b, {capacity = 1, leak_amount = -1, leak_interval = SEC}), err_of(ratelimit.Config_Error.Invalid_Amount))
	testing.expect_value(t, ratelimit.leaky_bucket_init(&b, {capacity = 1, leak_amount = 1}), err_of(ratelimit.Config_Error.Invalid_Interval))

	_ = ratelimit.leaky_bucket_init(&b, {capacity = 2, leak_amount = 1, leak_interval = SEC})
	_, err = ratelimit.leaky_bucket_take(&b, 0)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Invalid_Cost))
	_, err = ratelimit.leaky_bucket_take(&b, 3)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Cost_Exceeds_Capacity))
}

@(test)
test_leaky_bucket_reset_empties :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	b: ratelimit.Leaky_Bucket
	_ = ratelimit.leaky_bucket_init(&b, {capacity = 2, leak_amount = 1, leak_interval = SEC}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.leaky_bucket_take(&b, 2)
	ratelimit.leaky_bucket_reset(&b)
	testing.expect_value(t, ratelimit.leaky_bucket_level(&b), 0)
}

// ---------------------------------------------------------------------------
// Sliding window log
// ---------------------------------------------------------------------------

@(test)
test_window_log_allows_up_to_limit :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	c: ratelimit.Manual_Clock
	l: ratelimit.Sliding_Window_Log
	err := ratelimit.sliding_window_log_init(&l, {limit = 3, window = SEC}, ratelimit.manual_clock(&c), track_begin(&track))
	testing.expect_value(t, err, nil)
	defer ratelimit.sliding_window_log_destroy(&l)
	for _ in 0 ..< 3 {
		testing.expect(t, ratelimit.sliding_window_log_allow(&l))
	}
	testing.expect(t, !ratelimit.sliding_window_log_allow(&l))
	testing.expect_value(t, ratelimit.sliding_window_log_remaining(&l), 0)
}

@(test)
test_window_log_slides_exactly :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	c: ratelimit.Manual_Clock
	l: ratelimit.Sliding_Window_Log
	_ = ratelimit.sliding_window_log_init(&l, {limit = 2, window = SEC}, ratelimit.manual_clock(&c), track_begin(&track))
	defer ratelimit.sliding_window_log_destroy(&l)
	testing.expect(t, ratelimit.sliding_window_log_allow(&l)) // t=0
	ratelimit.manual_clock_advance(&c, 400 * MS)
	testing.expect(t, ratelimit.sliding_window_log_allow(&l)) // t=400ms
	d, _ := ratelimit.sliding_window_log_take(&l)
	testing.expect(t, !d.allowed)
	testing.expect_value(t, d.retry_after, 600 * MS)
	testing.expect_value(t, d.reset_after, SEC)
	ratelimit.manual_clock_advance(&c, 599 * MS)
	testing.expect(t, !ratelimit.sliding_window_log_allow(&l))
	ratelimit.manual_clock_advance(&c, 1 * MS)
	testing.expect(t, ratelimit.sliding_window_log_allow(&l))
	testing.expect(t, !ratelimit.sliding_window_log_allow(&l))
}

@(test)
test_window_log_multi_cost_retry_after :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	c: ratelimit.Manual_Clock
	l: ratelimit.Sliding_Window_Log
	_ = ratelimit.sliding_window_log_init(&l, {limit = 4, window = SEC}, ratelimit.manual_clock(&c), track_begin(&track))
	defer ratelimit.sliding_window_log_destroy(&l)
	for _ in 0 ..< 4 {
		_ = ratelimit.sliding_window_log_allow(&l)
		ratelimit.manual_clock_advance(&c, 100 * MS)
	}
	// Grants at 0, 100, 200, 300 ms; now is 400 ms. Three units need the
	// grants at 0, 100 and 200 ms to expire, which happens at 1200 ms.
	d, err := ratelimit.sliding_window_log_take(&l, 3)
	testing.expect_value(t, err, nil)
	testing.expect(t, !d.allowed)
	testing.expect_value(t, d.retry_after, 800 * MS)
	ratelimit.manual_clock_advance(&c, d.retry_after)
	d, _ = ratelimit.sliding_window_log_take(&l, 3)
	testing.expect(t, d.allowed)
	testing.expect_value(t, d.remaining, 0)
}

@(test)
test_window_log_wraps_ring_buffer :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	c: ratelimit.Manual_Clock
	l: ratelimit.Sliding_Window_Log
	_ = ratelimit.sliding_window_log_init(&l, {limit = 3, window = 10 * MS}, ratelimit.manual_clock(&c), track_begin(&track))
	defer ratelimit.sliding_window_log_destroy(&l)
	allowed := 0
	for _ in 0 ..< 100 {
		if ratelimit.sliding_window_log_allow(&l) {
			allowed += 1
		}
		ratelimit.manual_clock_advance(&c, 2 * MS)
	}
	// 200 ms in total with at most 3 grants per 10 ms: 3 grants every 5 steps.
	testing.expect_value(t, allowed, 60)
}

@(test)
test_window_log_rejects_bad_input :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	alloc := track_begin(&track)
	l: ratelimit.Sliding_Window_Log
	testing.expect_value(t, ratelimit.sliding_window_log_init(&l, {limit = 0, window = SEC}, {}, alloc), err_of(ratelimit.Config_Error.Invalid_Limit))
	testing.expect_value(t, ratelimit.sliding_window_log_init(&l, {limit = 1, window = 0}, {}, alloc), err_of(ratelimit.Config_Error.Invalid_Window))
	_, err := ratelimit.sliding_window_log_take(&l)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Not_Initialized))
	testing.expect_value(t, ratelimit.sliding_window_log_remaining(&l), 0)

	_ = ratelimit.sliding_window_log_init(&l, {limit = 2, window = SEC}, {}, alloc)
	defer ratelimit.sliding_window_log_destroy(&l)
	_, err = ratelimit.sliding_window_log_take(&l, 0)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Invalid_Cost))
	_, err = ratelimit.sliding_window_log_take(&l, 3)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Cost_Exceeds_Capacity))
}

@(test)
test_window_log_reports_allocation_failure :: proc(t: ^testing.T) {
	l: ratelimit.Sliding_Window_Log
	err := ratelimit.sliding_window_log_init(&l, {limit = 8, window = SEC}, {}, runtime.nil_allocator())
	testing.expect_value(t, err, err_of(runtime.Allocator_Error.Out_Of_Memory))
	_, err = ratelimit.sliding_window_log_take(&l)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Not_Initialized))
}

@(test)
test_window_log_reset_forgets_grants :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	c: ratelimit.Manual_Clock
	l: ratelimit.Sliding_Window_Log
	_ = ratelimit.sliding_window_log_init(&l, {limit = 1, window = SEC}, ratelimit.manual_clock(&c), track_begin(&track))
	defer ratelimit.sliding_window_log_destroy(&l)
	testing.expect(t, ratelimit.sliding_window_log_allow(&l))
	ratelimit.sliding_window_log_reset(&l)
	testing.expect(t, ratelimit.sliding_window_log_allow(&l))
}

// ---------------------------------------------------------------------------
// Sliding window counter
// ---------------------------------------------------------------------------

@(test)
test_window_counter_allows_up_to_limit :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	w: ratelimit.Sliding_Window_Counter
	err := ratelimit.sliding_window_counter_init(&w, {limit = 5, window = SEC}, ratelimit.manual_clock(&c))
	testing.expect_value(t, err, nil)
	for _ in 0 ..< 5 {
		testing.expect(t, ratelimit.sliding_window_counter_allow(&w))
	}
	d, _ := ratelimit.sliding_window_counter_take(&w)
	testing.expect(t, !d.allowed)
	testing.expect_value(t, d.remaining, 0)
	testing.expect_value(t, d.reset_after, 2 * SEC)
}

@(test)
test_window_counter_weights_previous_window :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	w: ratelimit.Sliding_Window_Counter
	_ = ratelimit.sliding_window_counter_init(&w, {limit = 10, window = SEC}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.sliding_window_counter_take(&w, 10)
	// A quarter into the next window, 75% of the previous 10 still count.
	ratelimit.manual_clock_advance(&c, 1250 * MS)
	testing.expect_value(t, ratelimit.sliding_window_counter_remaining(&w), 2)
	d, _ := ratelimit.sliding_window_counter_take(&w, 2)
	testing.expect(t, d.allowed)
	testing.expect_value(t, d.remaining, 0)
}

@(test)
test_window_counter_retry_after_within_window :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	w: ratelimit.Sliding_Window_Counter
	_ = ratelimit.sliding_window_counter_init(&w, {limit = 10, window = SEC}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.sliding_window_counter_take(&w, 10)
	ratelimit.manual_clock_advance(&c, SEC)
	// Previous = 10, current = 0. Five units need the weight to fall to 5.
	d, _ := ratelimit.sliding_window_counter_take(&w, 5)
	testing.expect(t, !d.allowed)
	testing.expect_value(t, d.retry_after, 500 * MS)
	ratelimit.manual_clock_advance(&c, d.retry_after - 1)
	testing.expect_value(t, ratelimit.sliding_window_counter_remaining(&w), 4)
	ratelimit.manual_clock_advance(&c, 1)
	d, _ = ratelimit.sliding_window_counter_take(&w, 5)
	testing.expect(t, d.allowed)
}

@(test)
test_window_counter_retry_after_spans_next_window :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	w: ratelimit.Sliding_Window_Counter
	_ = ratelimit.sliding_window_counter_init(&w, {limit = 4, window = SEC}, ratelimit.manual_clock(&c))
	ratelimit.manual_clock_advance(&c, 200 * MS)
	_, _ = ratelimit.sliding_window_counter_take(&w, 4)
	d, _ := ratelimit.sliding_window_counter_take(&w, 2)
	testing.expect(t, !d.allowed)
	// 800 ms to the next window, then the 4 previous grants must decay to 2.
	testing.expect_value(t, d.retry_after, 1300 * MS)
	ratelimit.manual_clock_advance(&c, d.retry_after)
	d, _ = ratelimit.sliding_window_counter_take(&w, 2)
	testing.expect(t, d.allowed)
}

@(test)
test_window_counter_forgets_after_two_windows :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	w: ratelimit.Sliding_Window_Counter
	_ = ratelimit.sliding_window_counter_init(&w, {limit = 3, window = SEC}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.sliding_window_counter_take(&w, 3)
	ratelimit.manual_clock_advance(&c, 5 * SEC)
	testing.expect_value(t, ratelimit.sliding_window_counter_remaining(&w), 3)
}

@(test)
test_window_counter_rejects_bad_input :: proc(t: ^testing.T) {
	w: ratelimit.Sliding_Window_Counter
	_, err := ratelimit.sliding_window_counter_take(&w)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Not_Initialized))
	testing.expect_value(t, ratelimit.sliding_window_counter_remaining(&w), 0)
	testing.expect_value(t, ratelimit.sliding_window_counter_init(&w, {limit = -1, window = SEC}), err_of(ratelimit.Config_Error.Invalid_Limit))
	testing.expect_value(t, ratelimit.sliding_window_counter_init(&w, {limit = 1, window = -1}), err_of(ratelimit.Config_Error.Invalid_Window))

	_ = ratelimit.sliding_window_counter_init(&w, {limit = 2, window = SEC})
	_, err = ratelimit.sliding_window_counter_take(&w, -1)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Invalid_Cost))
	_, err = ratelimit.sliding_window_counter_take(&w, 3)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Cost_Exceeds_Capacity))
}

@(test)
test_window_counter_reset_clears_counts :: proc(t: ^testing.T) {
	c: ratelimit.Manual_Clock
	w: ratelimit.Sliding_Window_Counter
	_ = ratelimit.sliding_window_counter_init(&w, {limit = 2, window = SEC}, ratelimit.manual_clock(&c))
	_, _ = ratelimit.sliding_window_counter_take(&w, 2)
	ratelimit.sliding_window_counter_reset(&w)
	testing.expect_value(t, ratelimit.sliding_window_counter_remaining(&w), 2)
}

// ---------------------------------------------------------------------------
// Generic limiter
// ---------------------------------------------------------------------------

@(test)
test_limiter_wraps_every_algorithm :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	alloc := track_begin(&track)
	c: ratelimit.Manual_Clock
	configs := [4]ratelimit.Limiter_Config {
		ratelimit.Token_Bucket_Config{capacity = 2, refill_amount = 1, refill_interval = SEC},
		ratelimit.Leaky_Bucket_Config{capacity = 2, leak_amount = 1, leak_interval = SEC},
		ratelimit.Sliding_Window_Log_Config{limit = 2, window = SEC},
		ratelimit.Sliding_Window_Counter_Config{limit = 2, window = SEC},
	}
	for config, i in configs {
		l: ratelimit.Limiter
		err := ratelimit.limiter_init(&l, config, ratelimit.manual_clock(&c), alloc)
		testing.expectf(t, err == nil, "config %d: %v", i, err)
		testing.expect_value(t, ratelimit.limiter_remaining(&l), 2)
		testing.expect(t, ratelimit.limiter_allow(&l))
		testing.expect(t, ratelimit.limiter_allow(&l))
		testing.expect(t, !ratelimit.limiter_allow(&l))
		ratelimit.limiter_reset(&l)
		testing.expect_value(t, ratelimit.limiter_remaining(&l), 2)
		ratelimit.limiter_destroy(&l)
		testing.expect(t, l == nil)
	}
}

@(test)
test_limiter_nil_config_and_nil_limiter :: proc(t: ^testing.T) {
	l: ratelimit.Limiter
	testing.expect_value(t, ratelimit.limiter_init(&l, nil), err_of(ratelimit.Config_Error.Missing_Config))
	testing.expect_value(t, ratelimit.limiter_config_validate(nil), err_of(ratelimit.Config_Error.Missing_Config))
	_, err := ratelimit.limiter_take(&l)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Not_Initialized))
	testing.expect(t, !ratelimit.limiter_allow(&l))
	testing.expect_value(t, ratelimit.limiter_remaining(&l), 0)
	ratelimit.limiter_reset(&l)
	ratelimit.limiter_destroy(&l)
}

@(test)
test_limiter_init_failure_leaves_nil :: proc(t: ^testing.T) {
	l: ratelimit.Limiter
	err := ratelimit.limiter_init(&l, ratelimit.Token_Bucket_Config{capacity = 0, refill_amount = 1, refill_interval = SEC})
	testing.expect_value(t, err, err_of(ratelimit.Config_Error.Invalid_Capacity))
	testing.expect(t, l == nil)
}

// ---------------------------------------------------------------------------
// Keyed limiter
// ---------------------------------------------------------------------------

@(test)
test_keyed_limits_each_key_separately :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	c: ratelimit.Manual_Clock
	k: ratelimit.Keyed_Limiter
	err := ratelimit.keyed_limiter_init(
		&k,
		{limiter = ratelimit.Token_Bucket_Config{capacity = 2, refill_amount = 1, refill_interval = SEC}},
		ratelimit.manual_clock(&c),
		track_begin(&track),
	)
	testing.expect_value(t, err, nil)
	defer ratelimit.keyed_limiter_destroy(&k)
	testing.expect(t, ratelimit.keyed_limiter_allow(&k, "alice"))
	testing.expect(t, ratelimit.keyed_limiter_allow(&k, "alice"))
	testing.expect(t, !ratelimit.keyed_limiter_allow(&k, "alice"))
	testing.expect(t, ratelimit.keyed_limiter_allow(&k, "bob"))
	testing.expect_value(t, ratelimit.keyed_limiter_len(&k), 2)
	testing.expect_value(t, ratelimit.keyed_limiter_remaining(&k, "bob"), 1)
}

@(test)
test_keyed_copies_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	alloc := track_begin(&track)
	k: ratelimit.Keyed_Limiter
	_ = ratelimit.keyed_limiter_init(&k, {limiter = ratelimit.Sliding_Window_Counter_Config{limit = 1, window = SEC}}, {}, alloc)
	defer ratelimit.keyed_limiter_destroy(&k)
	key := fmt.aprintf("user-%d", 42, allocator = alloc)
	testing.expect(t, ratelimit.keyed_limiter_allow(&k, key))
	delete(key, alloc)
	testing.expect(t, ratelimit.keyed_limiter_contains(&k, "user-42"))
	testing.expect(t, !ratelimit.keyed_limiter_allow(&k, "user-42"))
}

@(test)
test_keyed_with_window_log_frees_everything :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	k: ratelimit.Keyed_Limiter
	_ = ratelimit.keyed_limiter_init(&k, {limiter = ratelimit.Sliding_Window_Log_Config{limit = 3, window = SEC}}, {}, track_begin(&track))
	defer ratelimit.keyed_limiter_destroy(&k)
	keys := [?]string{"a", "b", "c", "d"}
	for key in keys {
		testing.expect(t, ratelimit.keyed_limiter_allow(&k, key))
	}
	testing.expect(t, ratelimit.keyed_limiter_remove(&k, "b"))
	testing.expect(t, !ratelimit.keyed_limiter_remove(&k, "b"))
	testing.expect_value(t, ratelimit.keyed_limiter_len(&k), 3)
	ratelimit.keyed_limiter_clear(&k)
	testing.expect_value(t, ratelimit.keyed_limiter_len(&k), 0)
	testing.expect(t, ratelimit.keyed_limiter_allow(&k, "a"))
}

@(test)
test_keyed_remaining_for_unknown_key :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	alloc := track_begin(&track)
	configs := [4]ratelimit.Limiter_Config {
		ratelimit.Token_Bucket_Config{capacity = 7, refill_amount = 1, refill_interval = SEC},
		ratelimit.Leaky_Bucket_Config{capacity = 7, leak_amount = 1, leak_interval = SEC},
		ratelimit.Sliding_Window_Log_Config{limit = 7, window = SEC},
		ratelimit.Sliding_Window_Counter_Config{limit = 7, window = SEC},
	}
	for config in configs {
		k: ratelimit.Keyed_Limiter
		_ = ratelimit.keyed_limiter_init(&k, {limiter = config}, {}, alloc)
		testing.expect_value(t, ratelimit.keyed_limiter_remaining(&k, "nobody"), 7)
		testing.expect_value(t, ratelimit.keyed_limiter_len(&k), 0)
		ratelimit.keyed_limiter_destroy(&k)
	}
}

@(test)
test_keyed_max_keys_returns_error :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	k: ratelimit.Keyed_Limiter
	_ = ratelimit.keyed_limiter_init(
		&k,
		{limiter = ratelimit.Token_Bucket_Config{capacity = 1, refill_amount = 1, refill_interval = SEC}, max_keys = 2},
		{},
		track_begin(&track),
	)
	defer ratelimit.keyed_limiter_destroy(&k)
	_, err := ratelimit.keyed_limiter_take(&k, "a")
	testing.expect_value(t, err, nil)
	_, err = ratelimit.keyed_limiter_take(&k, "b")
	testing.expect_value(t, err, nil)
	_, err = ratelimit.keyed_limiter_take(&k, "c")
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Too_Many_Keys))
	testing.expect(t, !ratelimit.keyed_limiter_contains(&k, "c"))
	// Known keys keep working at the limit.
	_, err = ratelimit.keyed_limiter_take(&k, "a")
	testing.expect_value(t, err, nil)
}

@(test)
test_keyed_max_keys_prunes_idle_first :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	c: ratelimit.Manual_Clock
	k: ratelimit.Keyed_Limiter
	_ = ratelimit.keyed_limiter_init(
		&k,
		{
			limiter = ratelimit.Token_Bucket_Config{capacity = 1, refill_amount = 1, refill_interval = SEC},
			max_keys = 2,
			idle_timeout = 10 * SEC,
		},
		ratelimit.manual_clock(&c),
		track_begin(&track),
	)
	defer ratelimit.keyed_limiter_destroy(&k)
	_ = ratelimit.keyed_limiter_allow(&k, "old")
	ratelimit.manual_clock_advance(&c, 9 * SEC)
	_ = ratelimit.keyed_limiter_allow(&k, "fresh")
	ratelimit.manual_clock_advance(&c, 1 * SEC)
	_, err := ratelimit.keyed_limiter_take(&k, "new")
	testing.expect_value(t, err, nil)
	testing.expect(t, !ratelimit.keyed_limiter_contains(&k, "old"))
	testing.expect(t, ratelimit.keyed_limiter_contains(&k, "fresh"))
	testing.expect(t, ratelimit.keyed_limiter_contains(&k, "new"))
}

@(test)
test_keyed_prune_removes_only_idle_keys :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	alloc := track_begin(&track)
	c: ratelimit.Manual_Clock
	k: ratelimit.Keyed_Limiter
	_ = ratelimit.keyed_limiter_init(
		&k,
		{limiter = ratelimit.Sliding_Window_Log_Config{limit = 2, window = SEC}, idle_timeout = 5 * SEC},
		ratelimit.manual_clock(&c),
		alloc,
	)
	defer ratelimit.keyed_limiter_destroy(&k)
	// More idle keys than one prune batch holds.
	for i in 0 ..< 150 {
		key := fmt.aprintf("idle-%d", i, allocator = alloc)
		_ = ratelimit.keyed_limiter_allow(&k, key)
		delete(key, alloc)
	}
	ratelimit.manual_clock_advance(&c, 5 * SEC)
	_ = ratelimit.keyed_limiter_allow(&k, "active")
	testing.expect_value(t, ratelimit.keyed_limiter_prune(&k), 150)
	testing.expect_value(t, ratelimit.keyed_limiter_len(&k), 1)
	testing.expect_value(t, ratelimit.keyed_limiter_prune(&k), 0)
}

@(test)
test_keyed_prune_without_timeout_is_noop :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	c: ratelimit.Manual_Clock
	k: ratelimit.Keyed_Limiter
	_ = ratelimit.keyed_limiter_init(
		&k,
		{limiter = ratelimit.Token_Bucket_Config{capacity = 1, refill_amount = 1, refill_interval = SEC}},
		ratelimit.manual_clock(&c),
		track_begin(&track),
	)
	defer ratelimit.keyed_limiter_destroy(&k)
	_ = ratelimit.keyed_limiter_allow(&k, "a")
	ratelimit.manual_clock_advance(&c, 1000 * SEC)
	testing.expect_value(t, ratelimit.keyed_limiter_prune(&k), 0)
	testing.expect_value(t, ratelimit.keyed_limiter_len(&k), 1)
}

@(test)
test_keyed_rejects_bad_config :: proc(t: ^testing.T) {
	k: ratelimit.Keyed_Limiter
	bucket := ratelimit.Token_Bucket_Config{capacity = 1, refill_amount = 1, refill_interval = SEC}
	testing.expect_value(t, ratelimit.keyed_limiter_init(&k, {}), err_of(ratelimit.Config_Error.Missing_Config))
	testing.expect_value(t, ratelimit.keyed_limiter_init(&k, {limiter = bucket, max_keys = -1}), err_of(ratelimit.Config_Error.Invalid_Keyed_Config))
	testing.expect_value(t, ratelimit.keyed_limiter_init(&k, {limiter = bucket, idle_timeout = -SEC}), err_of(ratelimit.Config_Error.Invalid_Keyed_Config))
	testing.expect_value(
		t,
		ratelimit.keyed_limiter_init(&k, {limiter = ratelimit.Sliding_Window_Log_Config{limit = 0, window = SEC}}),
		err_of(ratelimit.Config_Error.Invalid_Limit),
	)
	_, err := ratelimit.keyed_limiter_take(&k, "a")
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Not_Initialized))
}

@(test)
test_keyed_bad_cost_adds_no_key :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	k: ratelimit.Keyed_Limiter
	_ = ratelimit.keyed_limiter_init(&k, {limiter = ratelimit.Leaky_Bucket_Config{capacity = 2, leak_amount = 1, leak_interval = SEC}}, {}, track_begin(&track))
	defer ratelimit.keyed_limiter_destroy(&k)
	_, err := ratelimit.keyed_limiter_take(&k, "a", 0)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Invalid_Cost))
	_, err = ratelimit.keyed_limiter_take(&k, "a", 3)
	testing.expect_value(t, err, err_of(ratelimit.Take_Error.Cost_Exceeds_Capacity))
	testing.expect_value(t, ratelimit.keyed_limiter_len(&k), 0)
}

@(test)
test_keyed_empty_key_is_valid :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	k: ratelimit.Keyed_Limiter
	_ = ratelimit.keyed_limiter_init(&k, {limiter = ratelimit.Sliding_Window_Counter_Config{limit = 1, window = SEC}}, {}, track_begin(&track))
	defer ratelimit.keyed_limiter_destroy(&k)
	testing.expect(t, ratelimit.keyed_limiter_allow(&k, ""))
	testing.expect(t, !ratelimit.keyed_limiter_allow(&k, ""))
	testing.expect(t, ratelimit.keyed_limiter_contains(&k, ""))
}

@(test)
test_keyed_reports_allocation_failure :: proc(t: ^testing.T) {
	k: ratelimit.Keyed_Limiter
	err := ratelimit.keyed_limiter_init(
		&k,
		{limiter = ratelimit.Token_Bucket_Config{capacity = 1, refill_amount = 1, refill_interval = SEC}},
		{},
		runtime.nil_allocator(),
	)
	testing.expect_value(t, err, nil)
	_, err = ratelimit.keyed_limiter_take(&k, "a")
	testing.expect(t, err != nil, "expected an allocator error")
	testing.expect_value(t, ratelimit.keyed_limiter_len(&k), 0)
	ratelimit.keyed_limiter_destroy(&k)
}

// ---------------------------------------------------------------------------
// Thread-safe wrappers
// ---------------------------------------------------------------------------

THREADS :: 8
ATTEMPTS :: 250

Shared :: struct {
	limiter: ^ratelimit.Sync_Limiter,
	keyed:   ^ratelimit.Sync_Keyed_Limiter,
	allowed: int,
}

@(test)
test_sync_limiter_grants_exact_capacity_across_threads :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	c: ratelimit.Manual_Clock
	l: ratelimit.Sync_Limiter
	err := ratelimit.sync_limiter_init(&l, ratelimit.Sliding_Window_Log_Config{limit = 1000, window = SEC}, ratelimit.manual_clock(&c), track_begin(&track))
	testing.expect_value(t, err, nil)
	defer ratelimit.sync_limiter_destroy(&l)

	shared := Shared{limiter = &l}
	threads: [THREADS]^thread.Thread
	for &th in threads {
		th = thread.create_and_start_with_poly_data(&shared, proc(s: ^Shared) {
			for _ in 0 ..< ATTEMPTS {
				if ratelimit.sync_limiter_allow(s.limiter) {
					sync.atomic_add(&s.allowed, 1)
				}
			}
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, shared.allowed, 1000)
	testing.expect_value(t, ratelimit.sync_limiter_remaining(&l), 0)
	ratelimit.sync_limiter_reset(&l)
	d, take_err := ratelimit.sync_limiter_take(&l, 10)
	testing.expect_value(t, take_err, nil)
	testing.expect_value(t, d.remaining, 990)
}

@(test)
test_sync_keyed_limiter_across_threads :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	defer track_end(t, &track)
	c: ratelimit.Manual_Clock
	k: ratelimit.Sync_Keyed_Limiter
	err := ratelimit.sync_keyed_limiter_init(
		&k,
		{limiter = ratelimit.Token_Bucket_Config{capacity = 100, refill_amount = 1, refill_interval = SEC}, idle_timeout = SEC},
		ratelimit.manual_clock(&c),
		track_begin(&track),
	)
	testing.expect_value(t, err, nil)
	defer ratelimit.sync_keyed_limiter_destroy(&k)

	shared := Shared{keyed = &k}
	threads: [THREADS]^thread.Thread
	for &th in threads {
		th = thread.create_and_start_with_poly_data(&shared, proc(s: ^Shared) {
			keys := [2]string{"even", "odd"}
			for i in 0 ..< ATTEMPTS {
				if ratelimit.sync_keyed_limiter_allow(s.keyed, keys[i % 2]) {
					sync.atomic_add(&s.allowed, 1)
				}
			}
		})
	}
	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}
	testing.expect_value(t, shared.allowed, 200)
	testing.expect_value(t, ratelimit.sync_keyed_limiter_len(&k), 2)
	testing.expect_value(t, ratelimit.sync_keyed_limiter_remaining(&k, "odd"), 0)
	_, take_err := ratelimit.sync_keyed_limiter_take(&k, "odd")
	testing.expect_value(t, take_err, nil)
	testing.expect(t, ratelimit.sync_keyed_limiter_remove(&k, "odd"))
	ratelimit.manual_clock_advance(&c, SEC)
	testing.expect_value(t, ratelimit.sync_keyed_limiter_prune(&k), 1)
	testing.expect_value(t, ratelimit.sync_keyed_limiter_len(&k), 0)
}

@(test)
test_sync_limiter_rejects_bad_config :: proc(t: ^testing.T) {
	l: ratelimit.Sync_Limiter
	testing.expect_value(t, ratelimit.sync_limiter_init(&l, nil), err_of(ratelimit.Config_Error.Missing_Config))
	testing.expect(t, !ratelimit.sync_limiter_allow(&l))
	k: ratelimit.Sync_Keyed_Limiter
	testing.expect_value(t, ratelimit.sync_keyed_limiter_init(&k, {max_keys = -1}), err_of(ratelimit.Config_Error.Invalid_Keyed_Config))
}
