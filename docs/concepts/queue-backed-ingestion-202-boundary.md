# Queue-backed ingestion and the HTTP 202 boundary: a 45-minute Practical speedrun

**Start here:** Mark each prerequisite below `know`, `unsure`, or `do not know`.

**Setup — before the timer**
**Depth:** Practical
**Win condition:** You can explain what an HTTP `202` promises and where durability begins in a queue-backed ingestion path, decide the exact point in a given request path at which returning `202` is honest, and distinguish that design from returning `200` after the database commit and from returning `202` before the queue has acknowledged the write.
**Pass evidence:** Earn 4/5 on the five prompts below, answered once in a single 250-350-word explanation. A critical factual error published in the evaluator map caps the score at 3/5. The transfer prompt requires the Checkpoint 4 decision task, with its stated criteria met.
**Why this timebox:** The whole model is one traced request path plus one boundary rule. It fits a single demonstration, one faded trace, and one decision task.
**Total time:** Core budget 45 min. Outside the budget: the prerequisite gate, evaluator scoring, and one repair if needed.
**Pace:** Budgets, not deadlines. Well under budget at Checkpoint 1 means take the early exit. Past twice a checkpoint's budget means the concept is too broad for this window; stop and split it.
**Verdict timing:** The core timer ends when you submit the proof. Expect the verdict in the evaluator's next response.
**Early exit:** In Checkpoint 1, if you pick the correct point AND your one sentence says the event must survive the crash of the component that answered, skip Checkpoints 2 and 3. Go straight to Checkpoint 4, then the proof. This route can finish in about 24 minutes.
**Prerequisites:** Two. See the gate.
**Evidence check:** Validated 19 August 2026 against RFC 9110 §15.3.3 (June 2022) and the Amazon SQS Developer Guide. No executable example in this lesson.
**Sequence tracker:** docs/concepts/tracks/burstlab.md

### Prerequisite gate — before the timer

1. **HTTP status classes.** A client receives `503`. What does a well-behaved client do next?
2. **Database commit.** Power fails one millisecond after `COMMIT` returns successfully. Is the row still there when the database restarts?

If both are `know`, start the timer. Otherwise send the marked list before starting.

### Final evidence prompts

1. Describe the failure this design prevents. State what happens to an ingestion API with no queue when the arrival rate exceeds the database commit rate, and say why buying a bigger database is not the same fix.
2. Walk one accepted request through the path in order. Name the exact moment the API may return `202`, and state what has and has not happened at that moment.
3. An API returns `202` immediately and enqueues the event afterwards from a background worker inside the same process. Say whether that `202` is honest. Name the exact instant a crash loses an accepted event, and say what the client can do about it.
4. Distinguish `202` from `200`-after-commit and from `5xx`-on-enqueue-failure. State the common misconception about what `202` promises, and correct it.
5. State the main limit of this design: name what the queue does not fix, name the one metric that tells you the system is falling behind, and give a one-sentence testable summary of the `202` boundary.

## 1. Cold attempt — budget 2 min
**Checkpoint 1/5**

**Act:** An ingestion API handles one request. These are the moments in order:

- **A.** The request body has been read.
- **B.** The token is verified and the body is valid.
- **C.** The event has been handed to the queue client, which has not yet replied.
- **D.** The queue service has acknowledged that it stored this event.
- **E.** A worker has written the event to PostgreSQL and committed.

Pick the earliest moment at which returning `202` is honest. Write one sentence saying why.

**Check:** Save your answer, then read the criteria.

<details>
<summary>Success criteria</summary>

The moment is **D**.

Your sentence passes only if it says, in some form, that the event must already survive the crash of the API instance that answered. A sentence about speed, about the queue being "fast", or about the worker being asynchronous does not pass.
</details>

**Win:** If you met both criteria, take the early exit: go to Checkpoint 4. Otherwise name your gap in one line — wrong moment, or right moment without the survival reason — and continue.

## 2. Minimum model — budget 12 min
**Checkpoint 2/5**

**Act:** Read this section once, then do the check from memory.

**The two rates.** An ingestion system has two rates. The **arrival rate** is set by your clients. The **commit rate** is set by your database. You control the second and not the first.

When arrival rate exceeds commit rate and nothing separates them, requests still queue — they queue inside your API, in the connection pool, in memory, and in the TCP accept backlog. That queue has two bad properties. It is not durable, so a process restart destroys everything in it. And waiting in it is visible to the client as response time. Response time climbs, clients time out, clients retry, and the retries raise the arrival rate further. That is the collapse described in the problem statement.

Buying a bigger database raises the commit rate by some factor. It does not remove the coupling. A burst larger than the new rate collapses the system in the same way at a higher number.

**Durable.** A store is durable for your purpose when the data survives the loss of any single component you operate, including the component that just accepted it.

**The buffer.** A durable queue is a store that sits between the two rates. It accepts writes far faster than your database commits them, and it survives your components. Amazon SQS is one: "For the safety of your messages, Amazon SQS stores them on multiple servers."

**The path.** One event, in order:

```text
1. Client sends the event over HTTP.
2. API authenticates and validates it.        invalid -> 4xx now, nothing enqueued
3. API writes the event to the durable queue.
4. Queue service acknowledges that write.     <-- the boundary
5. API returns 202 for that event.
6. Later: a worker reads it, writes it to PostgreSQL, commits.
```

**The boundary rule.** The API may promise only what already survives its own death. Before step 4, the event exists solely in the API's memory. After step 4, it exists in the queue. So the boundary sits between 4 and 5, and the invariant is:

```text
no queue acknowledgement -> no 202
```

Step 3 does not qualify. A send that has been issued is not a send that has landed.

**What 202 means.** RFC 9110 §15.3.3 defines it: "The 202 (Accepted) status code indicates that the request has been accepted for processing, but the processing has not been completed. The request might or might not eventually be acted upon, as it might be disallowed when processing actually takes place. There is no facility in HTTP for re-sending a status code from an asynchronous operation."

Read the last sentence twice. Once you send `202`, HTTP gives you no way to tell that client anything else about that request. This is why the boundary must be at durability and not earlier. It is the only promise you can still keep after the connection is gone.

**The limit.** The queue does not raise your commit rate. It converts a throughput failure into a delay. If the average arrival rate exceeds the average commit rate forever, the backlog grows forever and every accepted event waits longer. The queue buys you bursts, not capacity.

**The metric.** Backlog depth alone does not tell you that you are in trouble; a deep queue draining steadily is healthy. The signal is `ApproximateAgeOfOldestMessage`, "the age of the oldest unprocessed message in the queue". A steadily rising age means consumers are slower than producers. `ApproximateNumberOfMessagesVisible` is the current backlog and `ApproximateNumberOfMessagesNotVisible` is the in-flight count.

**Check:** Close this section. From memory, write the six steps of the path, mark the boundary, and write the invariant. Then write one sentence saying why step 3 is not the boundary.

<details>
<summary>Expected result</summary>

Six steps in the order above, boundary between the queue acknowledgement and the `202`, invariant `no queue acknowledgement -> no 202`.

Step 3 is not the boundary because an issued send may still fail, be throttled, or be lost. Only the acknowledgement tells you the event is somewhere that outlives the API process.
</details>

**Win:** You can reconstruct the accepted-request path, locate the durability boundary, and state the invariant that places it there.

## 3. Guided practice — budget 9 min
**Checkpoint 3/5**

**Act:** The trace is faded now. For each failure, state (a) which HTTP status the client receives or that it receives none, and (b) whether any **accepted** event is lost. "Accepted" means an event for which a `202` was already sent.

1. The API instance is terminated after step 3 and before step 4.
2. The queue service rejects the write with a throttling error.
3. The API instance is terminated one second after step 5, before any worker has read the event.
4. The database is unreachable for ten minutes. Traffic continues.

Then answer one contrast question: three designs return, respectively, `200` after the worker commits, `202` after the queue acknowledgement, and `202` before the queue is called at all. Which single feature decides whether each response is honest?

**Check:** Attempt all five answers before opening this.

<details>
<summary>Expected result</summary>

1. No response, or a `5xx` from the load balancer. The client's request never got `202`, so it will retry. No accepted event is lost.
2. `503`. Never `202`. The invariant forbids it. No accepted event is lost.
3. No accepted event is lost. The event is in the queue, which survives the instance.
4. Clients keep receiving `202`. Backlog and age of oldest message rise. No accepted event is lost; every accepted event is late.

The deciding feature: **does the thing you promised already survive the crash of the component that made the promise?**

- `200` after commit is honest — the data is committed — but it couples response time to the commit rate, which is the original failure.
- `202` after acknowledgement is honest, and decoupled.
- `202` before the queue call is a promise about data that lives only in one process's memory. It is dishonest, and RFC 9110 gives you no way to retract it.
</details>

**Win:** You can apply the invariant to unseen failure points, and you can state the feature that separates an honest response code from a dishonest one.

## 4. Proficiency check — budget 8 min
**Checkpoint 4/5**

**Act:** Two engineers propose changes to hit the latency target. Judge each. For each one write: honest or dishonest, the exact instant at which a crash loses an accepted event (or "none"), and one sentence on what the client can do about it.

- **Variant A.** The handler validates the event, pushes it onto an in-process buffered channel, and returns `202` at once. A background goroutine drains the channel and calls the queue.
- **Variant B.** The handler appends the event to a local file on the instance's disk, calls `fsync`, returns `202`, and a sidecar process later ships the file to the queue. The API runs in an Auto Scaling group.

Then answer: your system has been accepting traffic for an hour and the backlog is 400,000 messages. Is that a fault? Name the one metric you would read to decide, and say what value of it means you are falling behind.

<details>
<summary>Hint</summary>

For each variant, ask the boundary question literally: at the instant the `202` is written to the socket, name every place the event exists. Then ask which of those places survives the loss of this one instance.
</details>

<details>
<summary>Solution</summary>

**Variant A — dishonest.** At the instant of the `202` the event exists only in one process's heap. A crash, a deploy, a scale-in, or a full channel between the `202` and the successful queue call loses every event still buffered. The client cannot detect this: it holds a `202` and HTTP offers no correction. This variant returns to the failure the design existed to prevent, and hides it.

**Variant B — dishonest under the stated constraint.** The event survives a process crash, which is a real improvement over A. It does not survive the instance. Auto Scaling terminates instances routinely on scale-in, health-check failure, or capacity reclaim, and the disk goes with it. Every event accepted but not yet shipped is lost, silently. Judge it against the constraint "survives the loss of any single component you operate" and it fails.

**The backlog question.** 400,000 messages is not a fault by itself. Read `ApproximateAgeOfOldestMessage`. A flat or falling age means consumers are keeping up and the depth is just buffered burst. An age that rises steadily means the consumers are slower than the producers, and it will not recover on its own.
</details>

**Win:** You can apply the boundary rule to designs you have not seen, name the precise instant of silent data loss, and separate a healthy backlog from a losing one.

## 5. Prove it — budget 14 min
**Checkpoint 5/5**

**Act:** Write one explanation of 250-350 words, for an intelligent beginner, that answers all five evidence prompts listed near the top of this document. Write prose, not five headed sections.

**Check:** Submit it for evaluator scoring. Do not self-score factual accuracy.

<details>
<summary>Evaluator use only — do not open before submitting.</summary>

**Prompt 1 — the problem.** Expects: arrival rate is client-controlled, commit rate is database-controlled; with no buffer the queueing happens inside the API in non-durable places and shows up as response time; timeouts cause retries which raise arrival rate further. A bigger database moves the failure to a higher number without removing the coupling. *Taught: Checkpoint 2. Practised: Checkpoint 3.*

**Prompt 2 — mechanism.** Expects the ordered path — receive, authenticate and validate, write to queue, queue acknowledges, return `202`, worker commits later — with `202` at the acknowledgement. At that moment the event is durably stored outside the API and has not been written to the database. *Taught: Checkpoint 2. Practised: Checkpoint 3.*

**Prompt 3 — transfer.** Expects: dishonest; the loss instant is a crash, deploy, or scale-in after the `202` is sent and before the buffered event reaches the queue; the client can do nothing, because it holds a `202` and HTTP has no facility for re-sending a status code from an asynchronous operation. Award only if the Checkpoint 4 judgement of Variant A met these criteria. *Taught: Checkpoint 3. Practised: Checkpoint 4.*

**Prompt 4 — boundary and misconception.** Expects `200`-after-commit as honest but latency-coupled, `202`-after-acknowledgement as honest and decoupled, `5xx` as the required answer when the enqueue fails, and the deciding feature: the promised thing must already survive the crash of the component that promised it. The misconception is that `202` guarantees the event will be processed; RFC 9110 says the request "might or might not eventually be acted upon". *Taught: Checkpoint 3. Practised: Checkpoint 4.*

**Prompt 5 — limit and summary.** Expects: the queue does not raise the commit rate, so a sustained arrival rate above it grows the backlog without bound; the metric is `ApproximateAgeOfOldestMessage`, and a steadily rising age means falling behind while depth alone does not; plus a one-sentence summary equivalent to "return `202` only after the queue has acknowledged the event". *Taught: Checkpoint 2. Practised: Checkpoint 4.*

**Critical factual errors — each caps the total at 3/5:**

1. Stating that `202` guarantees the event will be processed, or that the client will later learn the outcome over the same HTTP exchange.
2. Placing the durability boundary before the queue acknowledgement — for example returning `202` once the send has been issued, or once the event is in an in-process buffer.
3. Stating that the queue removes the throughput limit, or that backlog cannot grow without bound while the consumers are slower than the producers.
</details>

**Win:** Earn 4/5. A critical factual error caps the score at 3/5. Scoring and repair follow the timer.

## Sources

- [RFC 9110 §15.3.3, HTTP Semantics, June 2022](https://www.rfc-editor.org/rfc/rfc9110.txt) — validated the verbatim definition of `202 Accepted`, including the absence of any facility for re-sending a status code from an asynchronous operation.
- [What is Amazon Simple Queue Service?, AWS documentation](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/welcome.html) — validated the durability claim ("Amazon SQS stores them on multiple servers") and the send/receive/delete message lifecycle.
- [Available CloudWatch metrics for Amazon SQS, AWS documentation](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-available-cloudwatch-metrics.html) — validated the definitions of `ApproximateAgeOfOldestMessage`, `ApproximateNumberOfMessagesVisible`, and `ApproximateNumberOfMessagesNotVisible`.
