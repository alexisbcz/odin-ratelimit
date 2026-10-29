// Example basic shows each ratelimit primitive on a simulated clock. Run it with `odin run examples/basic`.
package main

import ratelimit "../.."
import "core:fmt"
import "core:os"
import "core:time"

main :: proc() {
	// A Manual_Clock makes the output the same on every run.
	clock: ratelimit.Manual_Clock

	// A token bucket allows a burst of 3, then 1 request every 500 ms.
	bucket: ratelimit.Token_Bucket
	err := ratelimit.token_bucket_init(
		&bucket,
		{capacity = 3, refill_amount = 1, refill_interval = 500 * time.Millisecond},
		ratelimit.manual_clock(&clock),
	)
	if err != nil {
		fmt.eprintln("token bucket:", err)
		os.exit(1)
	}
	for i in 1 ..= 5 {
		decision, _ := ratelimit.token_bucket_take(&bucket)
		if decision.allowed {
			fmt.printfln("request %d: allowed, %d left", i, decision.remaining)
		} else {
			fmt.printfln("request %d: denied, retry in %v", i, decision.retry_after)
		}
	}

	// A keyed limiter gives every client its own sliding window.
	clients: ratelimit.Keyed_Limiter
	err = ratelimit.keyed_limiter_init(
		&clients,
		{
			limiter = ratelimit.Sliding_Window_Log_Config{limit = 2, window = time.Second},
			max_keys = 10_000,
			idle_timeout = time.Minute,
		},
		ratelimit.manual_clock(&clock),
	)
	if err != nil {
		fmt.eprintln("keyed limiter:", err)
		os.exit(1)
	}
	defer ratelimit.keyed_limiter_destroy(&clients)

	requests := [?]string{"10.0.0.1", "10.0.0.2", "10.0.0.1", "10.0.0.1"}
	for ip in requests {
		decision, take_err := ratelimit.keyed_limiter_take(&clients, ip)
		if take_err != nil {
			fmt.eprintln("keyed limiter:", take_err)
			os.exit(1)
		}
		fmt.printfln("%s: allowed=%v remaining=%d", ip, decision.allowed, decision.remaining)
	}

	// A leaky bucket spreads a burst out at 1 job every 200 ms.
	queue: ratelimit.Leaky_Bucket
	_ = ratelimit.leaky_bucket_init(
		&queue,
		{capacity = 4, leak_amount = 1, leak_interval = 200 * time.Millisecond},
		ratelimit.manual_clock(&clock),
	)
	for job in 1 ..= 5 {
		decision, _ := ratelimit.leaky_bucket_take(&queue)
		if decision.allowed {
			fmt.printfln("job %d: run after %v", job, decision.delay)
		} else {
			fmt.printfln("job %d: queue full, retry in %v", job, decision.retry_after)
		}
	}

	// Advancing the clock refills the bucket.
	ratelimit.manual_clock_advance(&clock, time.Second)
	fmt.println("tokens after 1s:", ratelimit.token_bucket_tokens(&bucket))
}
