# Micro-batching, long polling, and consumer throughput arithmetic: a 60-minute Practical speedrun

**Start here:** There are no prerequisites. Start Checkpoint 1.

**Setup — before the timer**
**Depth:** Practical
**Win condition:** You can explain how size-or-time micro-batches and SQS long polling move BurstLab events, calculate stage capacity, queue growth, and drain time from observed values, and distinguish batching efficiency from proven end-to-end throughput.
**Pass evidence:** Earn 4/5 on the five prompts below, answered once in a single 250–350-word explanation. A critical factual error published in the evaluator map caps the score at 3/5. The transfer point requires the calculations and diagnosis from the Checkpoint 4 task.
**Why this timebox:** The model must connect three asynchronous stages and apply one rate method without treating configured limits as measured capacity.
**Total time:** Core budget 60 min. Outside the budget: the prerequisite gate, evaluator scoring, and one repair if needed.
**Pace:** Budgets, not deadlines. Well under budget at Checkpoint 1 means take the early exit. Past twice a checkpoint's budget means the concept is too broad for this window; stop and split it.
**Verdict timing:** The core timer ends when you submit the proof. Expect the verdict in the evaluator's next response.
**Early exit:** If your Checkpoint 1 answer gives 2,000 events/s, rejects the 20-second-delay claim, and explains why maximum batch size is not average batch size, skip Checkpoints 2 and 3. Complete Checkpoint 4 and the proof. This route can finish in about 30 minutes.
**Prerequisites:** None.
**Evidence check:** Retrieved and validated 20 August 2026 against the BurstLab source course and current Amazon SQS documentation. The worked and transfer arithmetic was execution-verified with Python 3.12.3.
**Sequence tracker:** docs/concepts/tracks/burstlab.md

### Prerequisite gate — before the timer

None. Start the core timer and continue to Checkpoint 1.

### Final evidence prompts

1. Explain why BurstLab uses a size-or-time rule for both producer and database micro-batches. Trace one sparse event and one burst event, naming which limit can end each batch and the latency-versus-efficiency tradeoff.
2. Trace an event from a producer batch, through an SQS long poll, into a database batch. Explain why `WaitTimeSeconds: 20` is not a 20-second message delay, why a receive can return fewer than 10 messages, and how receive loops feed larger database batches.
3. For the Checkpoint 4 case, calculate producer request demand and capacity, required producer lanes, receive capacity, database capacity, the bottleneck, backlog after 600 seconds, and drain time. State whether the original producer can accept 15,000 events/s.
4. Correct these three misconceptions: a configured maximum is the average batch size; long polling limits receive throughput to `10 / 20`; batching by itself proves 15,000 events/s. Distinguish request demand, a capacity estimate, and measured proof.
5. State the rate, stability, backlog, and drain equations. Name the main limitation of this arithmetic, and give one observable result that would falsify a claim of stable consumer throughput.

## 1. Cold attempt — budget 3 min
**Checkpoint 1/5**

**Act:** BurstLab has two API processes. Each process has one batcher that sends one SQS batch at a time. Suppose every batch contains 10 events and one complete send cycle averages 10 ms. Answer three questions:

1. What is the estimated combined producer capacity in events/s?
2. Does `WaitTimeSeconds: 20` force every available message to wait 20 seconds?
3. Does `MaxNumberOfMessages: 10` prove that every receive contains 10 messages?

**Check:** Save your answer, then reveal the criteria.

<details>
<summary>Success criteria</summary>

The two serial batchers complete about `2 / 0.010 = 200` calls/s. Ten events per call gives `200 × 10 = 2,000 events/s`.

No. A long poll returns sooner when a message becomes available. Also no: 10 is a maximum, and SQS can return fewer messages.
</details>

**Win:** If all three answers are correct and you used concurrency, successful items per cycle, and cycle time, take the early exit. Otherwise name one gap and continue.

## 2. Minimum model — budget 18 min
**Checkpoint 2/5**

**Act:** Trace one event through the three collectors. Then use the same units to calculate each stage.

### The literal path

```text
HTTP event
  |
  v
API collector: first event starts a 5 ms timer
  |-- flush at 10 events, or when the timer fires
  v
one SendMessageBatch call; each HTTP request waits for its item result
  |
  v
SQS Standard queue
  |
  v
worker receive loops: ReceiveMessage(max 10, wait up to 20 s)
  |-- each response can contain 1 to 10 messages
  v
shared in-memory channel
  |
  v
database collector: first message starts a 50 ms timer
  |-- flush at 1,000 messages, or when the timer fires
  v
one database transaction; commit before queue deletion
```

The two collectors use a **size-or-time rule**. The size limit improves efficiency under a burst. The timer prevents a sparse event from waiting indefinitely for a full batch. The timer can add collection latency, but a full batch ends the wait sooner.

BurstLab configures one serial producer batcher per API process. Each worker process configures 32 serial receive loops and four serial database write loops. Burst mode has two API processes and two worker processes. Therefore, it has two producer lanes, 64 receive lanes, and eight database lanes. These are independent in-flight lanes, not CPU-core counts. ([BurstLab source course](../../burstlab_15k_aws_beginner_course.md))

SQS batching spreads one service round trip across several messages. AWS documents that batched SQS actions can carry up to 10 messages and that concurrency plus batching can improve throughput. A batch can still contain individual failures, so count successful items rather than requested items. ([AWS SQS batching and horizontal scaling](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-throughput-horizontal-scaling-and-batching.html))

Long polling is a wait for useful work, not a batching timer. A positive wait enables long polling, and 20 seconds is the maximum wait. If a message is available, the call can return sooner. Long polling reduces empty and false-empty responses during sparse traffic. It does not force a message to sit for 20 seconds. ([AWS SQS short and long polling](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-short-and-long-polling.html))

`ReceiveMessage` returns up to 10 messages. It can return fewer than requested. The receive loops place their results into one channel, so a database batch can combine messages from many receive calls. The SQS receive limit of 10 is not the database batch limit of 1,000.

### One rate method

Use seconds for every time value.

```text
request demand = event rate / average successful batch size

stage capacity = concurrent serial lanes
                 × average successful items per completed cycle
                 / average cycle seconds

consumer capacity = minimum(receive capacity, database capacity, delete capacity)

backlog growth rate = max(0, queue ingress rate - consumer capacity)
backlog after t      = backlog growth rate × t
drain after stop     = backlog / consumer capacity
```

If new traffic continues during drain, replace the last denominator with `consumer capacity - continuing ingress rate`. The result is meaningful only when that difference is positive.

Use the observed average batch size, not the configured maximum. Use the full serialized cycle time for one lane. For a producer, the cycle includes collection and the SQS call. For a receive loop, it includes the call and local handoff. For a write loop, it includes collection and the database transaction.

### Worked BurstLab estimate

At a target of 15,000 events/s with full producer batches of 10:

```text
send request demand = 15,000 / 10 = 1,500 calls/s
```

Two serial producer lanes must each complete 750 calls/s. Their required average cycle is:

```text
required cycle <= 2 lanes × 10 events / 15,000 events/s
               <= 0.001333 s
               <= 1.33 ms
```

This is a requirement, not a measurement. The configured batch size does not show that BurstLab meets it.

Now assume the queue does receive 15,000 events/s for 600 seconds. Use these observed consumer averages:

```text
receive: 64 lanes, 8 messages/cycle, 0.040 s/cycle
database: 8 lanes, 400 rows/cycle, 0.250 s/cycle
delete: measured above both other stages
```

Then:

```text
receive capacity  = 64 × 8 / 0.040   = 12,800 events/s
database capacity = 8 × 400 / 0.250 = 12,800 events/s
consumer capacity = min(12,800, 12,800) = 12,800 events/s
backlog growth    = 15,000 - 12,800 = 2,200 events/s
backlog at stop   = 2,200 × 600 = 1,320,000 events
drain after stop  = 1,320,000 / 12,800 = 103.125 s
```

The queue absorbs the temporary difference. It does not remove it. If average ingress stays above consumer capacity forever, the queue grows forever.

### What the estimate does not prove

The equation compresses variable behavior into averages. Batch sizes, call latency, transaction time, partial failures, retries, resource contention, and delete work can change under load. Equality also gives no safety margin.

A stable-throughput claim needs observation. During a steady input rate below the claimed capacity, queue depth and age should not keep rising. Counts must also reconcile after drain. If age or depth has a sustained upward trend, the capacity claim is false for that run even when the configuration looks large enough.

**Check:** Close this section. Rebuild the path from memory and write the four equations. Then explain why these two divisions answer different questions:

```text
15,000 events/s / 10 events/call
64 lanes × 8 events/cycle / 0.040 s/cycle
```

<details>
<summary>Expected result</summary>

The first division gives request demand: 1,500 send calls/s when the successful average is 10. It does not give producer capacity because it contains no concurrency or cycle time.

The second expression gives an estimated receive capacity: 12,800 messages/s. It uses 64 independent lanes, eight observed messages per completed cycle, and a 40 ms observed cycle.

The reconstructed path contains two separate size-or-time collectors. Long polling sits between them and returns sooner when work is available.
</details>

**Win:** You can trace the collectors, identify the independent lanes, and calculate demand, capacity, backlog, and drain with consistent units.

## 3. Guided practice — budget 12 min
**Checkpoint 3/5**

**Act:** Complete one trace and one faded calculation.

First trace two events:

- Event `S` arrives alone. Name the producer condition that releases it, what an already-open long poll does, and the database condition that eventually releases it.
- Event `B` arrives during a heavy burst. Name the condition that can release each collector before its timer fires.

Then analyze this measured case:

```text
queue ingress: 9,000 events/s
producer: 3 lanes, average batch 9, average cycle 0.002 s
receive: 32 lanes, average response 9, average cycle 0.030 s
database: 4 lanes, average batch 300, average cycle 0.125 s
delete: not the bottleneck
```

Calculate send-request demand, all three event capacities, the bottleneck, and headroom. Then raise queue ingress to 10,500 events/s for 120 seconds. Calculate the queue backlog and drain time after ingress stops.

**Check:** Attempt the trace and calculations before opening the result.

<details>
<summary>Expected result</summary>

For sparse event `S`, the producer's 5 ms timer releases a partial batch if the size limit does not win. An open long poll returns when SQS makes the message available; it does not wait for the full 20 seconds. The database's 50 ms timer releases a partial database batch if the size limit does not win.

For burst event `B`, 10 producer events can end the producer collection before 5 ms. A receive returns at most 10 messages as soon as SQS has work for it. Messages from many receive calls can make the database collector reach 1,000 before 50 ms.

```text
send demand       = 9,000 / 9 = 1,000 calls/s
producer capacity = 3 × 9 / 0.002 = 13,500 events/s
receive capacity  = 32 × 9 / 0.030 = 9,600 events/s
database capacity = 4 × 300 / 0.125 = 9,600 events/s
bottleneck        = 9,600 events/s
headroom          = 9,600 - 9,000 = 600 events/s
```

At 10,500 events/s, backlog grows by `10,500 - 9,600 = 900 events/s`. After 120 seconds it is `108,000` events. With no new ingress, drain time is `108,000 / 9,600 = 11.25 seconds` under the stated constant-capacity assumption.
</details>

**Win:** You can reproduce the trace and rate method with less guidance, including the sparse and burst behavior.

## 4. Proficiency check — budget 12 min
**Checkpoint 4/5**

**Act:** Diagnose this 15,000-events/s design from the measured averages. The target hold is 600 seconds.

```text
producer: 2 serial lanes, average successful batch 8, average cycle 0.008 s
receive: 64 lanes, average response 6, average cycle 0.032 s
database: 8 lanes, average committed batch 450, average cycle 0.200 s
delete: measured above 18,000 messages/s
```

Calculate:

1. Producer send-request demand and producer event capacity.
2. The minimum total producer lanes needed at the same batch size and cycle time.
3. Receive capacity, database capacity, and the consumer bottleneck.
4. Assuming a corrected producer enqueues 15,000 events/s, backlog at the end of the hold and drain time after traffic stops.
5. Whether these calculations prove that the system sustains 15,000 accepted and committed events/s.

Also explain why `WaitTimeSeconds: 20` does not belong in the high-backlog capacity denominator.

**Check:** Compare your attempt with the criteria. Use the hint only if needed, then open the solution.

<details>
<summary>Success criteria</summary>

Your result includes 1,875 required send calls/s, 2,000 events/s of producer capacity, 15 required producer lanes, 12,000 events/s of receive capacity, 18,000 rows/s of database capacity, a receive bottleneck, 1,800,000 queued events, and a 150-second drain. You reject the original producer's 15,000-events/s claim and do not treat the estimate as measured proof.
</details>

<details>
<summary>Hint</summary>

Use `ceil(target rate × cycle seconds / average items)` for required lanes. Calculate queue growth only after the question assumes that a corrected producer enqueues the target rate.
</details>

<details>
<summary>Solution</summary>

```text
send demand       = 15,000 / 8 = 1,875 calls/s
producer capacity = 2 × 8 / 0.008 = 2,000 events/s
required lanes    = ceil(15,000 × 0.008 / 8) = 15 lanes

receive capacity  = 64 × 6 / 0.032 = 12,000 events/s
database capacity = 8 × 450 / 0.200 = 18,000 events/s
consumer capacity = min(12,000, 18,000, delete capacity) = 12,000 events/s

backlog growth    = 15,000 - 12,000 = 3,000 events/s
backlog at stop   = 3,000 × 600 = 1,800,000 events
drain after stop  = 1,800,000 / 12,000 = 150 s
```

The original producer cannot accept 15,000 events/s under the stated measurements. Adding enough producer concurrency is one possible repair, but it must be load-tested with bounded queues and service limits.

With a sustained backlog, SQS has messages available and a long poll can return sooner than 20 seconds. Use the observed 32 ms receive cycle in this estimate. The 20-second value is the maximum wait when useful work is not yet available.

The calculations are a diagnosis, not proof. Proof needs observed accepted and committed rates, successful batch sizes, cycle times, failures, and queue depth or age through the hold and drain.
</details>

**Win:** You can find separate producer and consumer bottlenecks, quantify the queue consequence, and state what must still be measured.

## 5. Prove it — budget 15 min
**Checkpoint 5/5**

**Act:** Write one 250–350-word explanation for an intelligent beginner that answers the five evidence prompts above. Use prose, not five headed sections.

**Check:** Submit it for evaluator scoring. Do not self-score factual accuracy.

<details>
<summary>Evaluator use only — do not open before submitting.</summary>

**Prompt 1 — problem and useful context.** Expects both size-or-time collectors: producer 10 or 5 ms, database 1,000 or 50 ms. A sparse event is released by time when size does not win; a burst can hit size first. Batching amortizes calls or transactions but trades this efficiency for collection delay. Taught: Checkpoint 2. Practised: Checkpoint 3.

**Prompt 2 — mechanism through examples.** Expects the path producer collector, `SendMessageBatch`, SQS, concurrent `ReceiveMessage`, shared channel, database collector, and transaction. A long poll returns sooner when work is available; 20 seconds is the maximum wait. Receive can return fewer than its maximum of 10, and many responses can feed a database batch up to 1,000. Taught: Checkpoint 2. Practised: Checkpoint 3.

**Prompt 3 — transfer task.** Expects: 1,875 send calls/s; 2,000 producer events/s; 15 required producer lanes; 12,000 receive events/s; 18,000 database rows/s; receive as consumer bottleneck; 1,800,000 backlog; 150-second drain; original producer cannot accept 15,000 events/s under the stated measurements. Award this point only when the published Checkpoint 4 task criteria are met. Taught: Checkpoint 2. Practised: Checkpoint 4.

**Prompt 4 — boundary and misconceptions.** Expects maximum batch size to be separated from observed successful average; long-poll maximum wait to be separated from a high-backlog receive cycle; and batching efficiency to be separated from measured end-to-end throughput. Request demand lacks concurrency and cycle time, a capacity estimate uses them, and proof observes the running system. Taught: Checkpoint 2. Practised: Checkpoint 3.

**Prompt 5 — limit and testable summary.** Expects `request demand = rate / average batch`, `capacity = lanes × average successful items / cycle seconds`, consumer capacity as the minimum stage, backlog as positive ingress-minus-capacity times duration, and drain as backlog divided by spare or post-stop capacity. The main limit is that variable batches, latency, failures, retries, and contention are compressed into assumed averages. Sustained growth in queue depth or oldest-message age under a claimed stable load falsifies that capacity claim. Taught: Checkpoint 2. Practised: Checkpoint 4.

**Critical factual errors — each caps the total at 3/5:**

1. Stating that `WaitTimeSeconds: 20` makes every available message wait 20 seconds or limits receive throughput to `10 / 20` messages/s.
2. Treating a configured maximum batch size as the actual average, or claiming stage capacity without both concurrency and cycle time.
3. Stating that batching alone guarantees 15,000 events/s, or that a queue remains stable while sustained ingress exceeds sustained consumer capacity.
</details>

**Win:** Earn 4/5. A critical factual error caps the score at 3/5. Scoring and repair follow the timer.

## Sources

- [BurstLab source course](../../burstlab_15k_aws_beginner_course.md) — validated the implementation-specific batch windows, batch limits, loop counts, and burst-mode process counts used in the lesson.
- [Increasing throughput using horizontal scaling and action batching with Amazon SQS](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-throughput-horizontal-scaling-and-batching.html) — validated the concurrency model, the throughput benefit of amortizing round trips, the 10-message SQS batch boundary, and the need to inspect individual results.
- [Amazon SQS short and long polling](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-short-and-long-polling.html) — validated early return when messages are available, the 20-second maximum wait, and the reduction in empty and false-empty responses.
