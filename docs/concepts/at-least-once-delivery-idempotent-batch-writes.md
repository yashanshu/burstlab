# At-least-once delivery and idempotent batch writes: a 45-minute Practical speedrun

**Start here:** There are no prerequisites. Start Checkpoint 1.

**Setup — before the timer**
**Depth:** Practical
**Win condition:** You can explain why an SQS Standard queue can deliver the same message more than once, predict and repair BurstLab's commit-then-delete batch path across a crash, and distinguish an idempotent database effect from exactly-once delivery and from an unprotected side effect.
**Pass evidence:** Earn 4/5 on the five prompts below, answered once in a single 250–350-word explanation. A critical factual error published in the evaluator map caps the score at 3/5. The transfer point requires the corrected operation order and final row state from the Checkpoint 4 task.
**Why this timebox:** One message lifecycle, one mixed database batch, and three crash windows cover the complete practical model.
**Total time:** Core budget 45 min. Outside the budget: the prerequisite gate, evaluator scoring, and one repair if needed.
**Pace:** Budgets, not deadlines. Well under budget at Checkpoint 1 means take the early exit. Past twice a checkpoint's budget means the concept is too broad for this window; stop and split it.
**Verdict timing:** The core timer ends when you submit the proof. Expect the verdict in the evaluator's next response.
**Early exit:** If your Checkpoint 1 answer states two processing attempts, one final row, the uniqueness rule that suppresses the second write, and the commit-before-delete order, skip Checkpoints 2 and 3. Complete Checkpoint 4 and the proof. This route can finish in about 24 minutes.
**Prerequisites:** None.
**Evidence check:** Validated 19 August 2026 against the Amazon SQS Developer Guide, the Amazon SQS `DeleteMessageBatch` API reference, and PostgreSQL 18 documentation. The mixed-batch row-state example was execution-verified with Python 3.12.3 and SQLite 3.45.1 as a local semantic analogue; PostgreSQL-specific conflict behavior was validated against the PostgreSQL documentation.
**Sequence tracker:** docs/concepts/tracks/burstlab.md

### Prerequisite gate — before the timer

None. Start the core timer and continue to Checkpoint 1.

### Final evidence prompts

1. Explain why BurstLab must expect a queue message more than once. Give one concrete cause of redelivery, and show what can go wrong when a repeated side effect is not idempotent.
2. Trace one BurstLab message from receive through database commit and SQS delete. Then trace a crash after commit but before delete, including the retry and final database state.
3. Repair the unsafe worker order from Checkpoint 4. State the corrected order, explain how the unsafe order can lose event `D`, and give the final rows after the stated crash and retry.
4. Distinguish at-least-once delivery, exactly-once processing, and an idempotent database effect. Correct the misconception that a visibility timeout or idempotency prevents duplicate processing attempts.
5. State the main limit of BurstLab's protection. Use the composite key to explain a changed timestamp and a changed value, then give the commit/delete invariant and one test that could falsify the claim that the write path is duplicate-safe.

## 1. Cold attempt — budget 2 min
**Checkpoint 1/5**

**Act:** A worker receives event `A`. It commits `A` to PostgreSQL and crashes before deleting the SQS message. The message later returns, and another worker processes it. Write three lines:

1. How many processing attempts occurred?
2. How many event rows must remain?
3. What operation order and database rule make that result safe?

**Check:** Save your answer, then reveal the criteria.

<details>
<summary>Success criteria</summary>

There were two processing attempts and one final row. The first worker committed before it tried to delete the queue message. A primary key or unique constraint identifies the logical event, and `ON CONFLICT DO NOTHING` turns the second insert into a no-op.

The answer does not claim that SQS delivered exactly once or that the second worker did not run.
</details>

**Win:** If you met all four early-exit requirements, go to Checkpoint 4. Otherwise name one gap—attempt count, row count, ordering, or uniqueness—and continue.

## 2. Minimum model — budget 13 min
**Checkpoint 2/5**

**Act:** Follow event `A` through the literal state changes. Then reconstruct the path from memory.

**Three different claims.** Keep these terms separate:

- **At-least-once delivery:** a message can have one or more delivery attempts. Duplicate attempts are allowed.
- **Exactly-once processing:** the handler and all its effects occur once. BurstLab does not have this guarantee.
- **Idempotent database effect:** applying the same logical event again leaves the observed database state the same as applying it once.

Idempotency changes the effect of a retry. It does not stop the retry from occurring.

**The queue state.** Receiving an SQS message does not remove it. SQS keeps the message and normally hides it from other consumers for the visibility timeout. If the worker does not delete it before that timeout expires, the message becomes visible again. SQS also warns that its at-least-once model does not absolutely prevent another delivery during the visibility period. ([AWS visibility-timeout documentation](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html))

**The database identity.** BurstLab defines one logical event with this primary key:

```sql
PRIMARY KEY (tenant_id, request_id, event_ts)
```

All three fields form the identity. A matching `request_id` with a different `event_ts` is a different key and can create another row.

**The batch write.** One worker can collect many received messages. BurstLab starts one database transaction, copies valid rows into a temporary staging table, and runs:

```sql
INSERT INTO events (tenant_id, request_id, event_ts, value)
SELECT tenant_id, request_id, event_ts, value FROM stage_events
ON CONFLICT DO NOTHING;
```

For each proposed row, PostgreSQL either inserts it or takes the conflict action when a usable unique constraint rejects the key. `DO NOTHING` leaves the existing row unchanged. ([PostgreSQL 18 `INSERT` documentation](https://www.postgresql.org/docs/current/sql-insert.html))

Suppose the database already contains:

```text
(course-tenant, A, 12:00:00, first-A)
```

A replay with the same three key fields and value `changed-A` does not update that row. The existing value stays `first-A`. This is duplicate-safe, but it can hide contradictory payloads unless another check reports them.

**The ownership path.** The safe sequence is:

```text
1. SQS delivers messages; they remain in the queue but become invisible.
2. Worker begins one database transaction for the batch.
3. Worker stages rows and inserts with ON CONFLICT DO NOTHING.
4. PostgreSQL commits the transaction.                 <-- durable effect
5. Worker sends only committed message receipts for SQS deletion.
6. SQS reports success or failure for each delete entry.
```

`DeleteMessageBatch` can return HTTP `200` while individual entries fail. Each entry has its own result, so the consumer must inspect the `Successful` and `Failed` lists. ([AWS `DeleteMessageBatch` API reference](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_DeleteMessageBatch.html)) A failed delete can lead to another delivery. The database rule makes that retry safe.

**The crash windows.** Use the database commit as the boundary:

| Failure point | Durable database state | Queue state | Safe next event |
|---|---|---|---|
| Before commit | No batch effect | Not deleted | Messages return; retry the batch |
| After commit, before delete | Batch effect exists | Not deleted | Messages can return; conflicts become no-ops |
| After delete, before commit | Batch effect might not exist | Messages are gone | Accepted events can be lost; this order is forbidden |

The invariant is:

```text
no database commit -> no SQS delete
```

For a successful mixed batch, newly inserted rows and rows skipped as duplicates can both be deleted after commit. The desired database state exists for both.

**The limit.** The primary key protects only the `events` insert and only according to those three fields. It does not make an email, charge, counter increment, or another table update idempotent. Each extra effect needs its own duplicate-safe design or must share the same transaction and identity rule.

**Check:** Close the section. From memory, write the six ownership steps and the invariant. Then trace the three crash windows. Finally classify these two repeats:

1. Same tenant, request ID, and timestamp; different `value`.
2. Same tenant and request ID; different timestamp.

<details>
<summary>Expected result</summary>

The six steps and invariant match the path above. Before commit, the batch has no durable effect and is retried. After commit but before delete, a replay is safe because conflicting rows are skipped. Delete before commit can lose an event.

Repeat 1 has the same key, so `DO NOTHING` preserves the existing value. Repeat 2 has a different composite key, so it inserts another row.
</details>

**Win:** You can reconstruct the queue-to-database ownership path, locate the only safe delete boundary, and predict how the composite key treats a replay.

## 3. Guided practice — budget 8 min
**Checkpoint 3/5**

**Act:** The database initially has one row:

```text
(course-tenant, A, 12:00:00, first-A)
```

The next received batch contains:

```text
1. (course-tenant, A, 12:00:00, changed-A)
2. (course-tenant, B, 12:00:01, first-B)
3. (course-tenant, A, 12:00:02, second-A)
```

Predict the rows after one successful commit. Mark each batch item `inserted` or `skipped`. State which receipts are now eligible for deletion.

Then add this result: the delete batch succeeds for entries 1 and 3 but fails for entry 2. Predict what can happen to entry 2 and what its retry does to the database.

**Check:** Attempt the complete trace before opening the result.

<details>
<summary>Expected result</summary>

Item 1 is skipped because all three key fields match the existing row. Its attempted `changed-A` value does not replace `first-A`. Items 2 and 3 are inserted because each has a new composite key.

The final rows are:

```text
(course-tenant, A, 12:00:00, first-A)
(course-tenant, A, 12:00:02, second-A)
(course-tenant, B, 12:00:01, first-B)
```

All three receipts are eligible for deletion because the transaction committed the desired state for every item, including the skipped duplicate. Entry 2 can become visible and be delivered again. Its retry conflicts with the existing `B` key, changes no row, and can then be deleted.
</details>

**Win:** You can predict a mixed batch with a duplicate, two new keys, and a partial queue-delete failure.

## 4. Proficiency check — budget 8 min
**Checkpoint 4/5**

**Act:** Review this unsafe worker. The database already contains event `A` from Checkpoint 3. The received batch contains the same-key `A` with `changed-A` and a new event `D`.

```text
1. Receive the batch from SQS.
2. BEGIN; stage both rows; INSERT ... ON CONFLICT DO NOTHING.
3. Delete both SQS messages.
4. COMMIT.
```

The worker crashes after step 3 and before step 4.

Write a corrected five-line sequence. Then state:

- why the unsafe sequence can lose `D`;
- the database rows after the same crash point in your corrected sequence;
- what happens when both messages are delivered again;
- whether the result proves exactly-once processing.

**Check:** Compare your attempt with the criteria. Use the hint only if needed, then open the solution.

<details>
<summary>Success criteria</summary>

Your sequence places `COMMIT` before every SQS delete. You state that the unsafe crash can roll back `D` after its only queue copy was deleted. In the corrected trace, `A` keeps `first-A`, `D` exists once, a retry changes neither row, and two handler attempts do not become exactly-once processing.
</details>

<details>
<summary>Hint</summary>

At the crash instant, list the durable systems that own `D`. An uncommitted transaction is not a durable owner.
</details>

<details>
<summary>Solution</summary>

```text
1. Receive the batch from SQS.
2. BEGIN; stage both rows.
3. INSERT ... ON CONFLICT DO NOTHING.
4. COMMIT.
5. Delete each committed message from SQS and inspect each result.
```

In the unsafe order, SQS no longer owns `D`, and the crash can abort the uncommitted insert. No system retains the event, so it is lost.

In the corrected order, the analogous crash is after commit and before delete. `A` remains `(A, 12:00:00, first-A)`, and `D` is present once. Both messages can return. Both retry attempts conflict with durable rows, so the database remains unchanged. The handler ran twice; the database effect is idempotent, not exactly-once processing.
</details>

**Win:** You can repair an unsafe consumer, prove which system owns each event at the crash boundary, and predict the final state after replay.

## 5. Prove it — budget 14 min
**Checkpoint 5/5**

**Act:** Write one 250–350-word explanation for an intelligent beginner that answers the five evidence prompts above. Use prose, not five headed sections.

**Check:** Submit it for evaluator scoring. Do not self-score factual accuracy.

<details>
<summary>Evaluator use only — do not open before submitting.</summary>

**Prompt 1 — problem and context.** Expects: receive does not delete; a crash, visibility expiry, or failed delete can cause another delivery; at-least-once permits duplicate attempts. A non-idempotent effect such as an unguarded counter, charge, email, or append can happen twice. Taught: Checkpoint 2. Practised: Checkpoint 3.

**Prompt 2 — mechanism through the example.** Expects the order receive and hide, begin transaction, stage, conflict-aware insert, commit, then delete and inspect per-entry results. A crash after commit but before delete leaves the row durable and the message eligible for redelivery; the retry conflicts and leaves one final row. Taught: Checkpoint 2. Practised: Checkpoint 3.

**Prompt 3 — transfer task.** Expects the corrected Checkpoint 4 order with `COMMIT` before delete; the unsafe order can delete `D` and then lose its uncommitted row; the corrected crash leaves original `A` unchanged and one durable `D`; replay changes neither. Award this point only when the published Checkpoint 4 task criteria are met. Taught: Checkpoint 2. Practised: Checkpoint 4.

**Prompt 4 — boundary and misconception.** Expects: at-least-once allows multiple delivery attempts; exactly-once processing would require one handler effect; idempotency permits repeated attempts but preserves the same database result. A visibility timeout normally hides work but is not an exactly-once lock, and idempotency does not prevent a handler from running again. Taught: Checkpoint 2. Practised: Checkpoint 4.

**Prompt 5 — limit and testable summary.** Expects: protection is limited to the `events` insert governed by `(tenant_id, request_id, event_ts)`; a changed timestamp is a new key and inserts, while a changed value under the same key is ignored and the existing value remains; other side effects need separate protection. The invariant is `no database commit -> no SQS delete`. A valid test processes the same full key twice, including a forced post-commit/pre-delete retry, and verifies one unchanged row. Taught: Checkpoint 2. Practised: Checkpoint 3.

**Critical factual errors — each caps the total at 3/5:**

1. Stating that SQS at-least-once delivery or the visibility timeout prevents duplicate delivery or guarantees exactly-once processing.
2. Stating that deleting the SQS message before a successful database commit is safe.
3. Stating that `ON CONFLICT DO NOTHING` protects every repeated event or side effect regardless of the unique key and transaction boundary.
</details>

**Win:** Earn 4/5. A critical factual error caps the score at 3/5. Scoring and repair follow the timer.

## Sources

- [Amazon SQS visibility timeout, AWS documentation](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html) — validated the receive/hide/delete lifecycle, redelivery after timeout, and the fact that at-least-once delivery can still produce duplicate attempts during the visibility period.
- [`DeleteMessageBatch`, Amazon SQS API reference](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_DeleteMessageBatch.html) — validated per-entry success and failure results, including partial failure with an HTTP `200` response.
- [`INSERT`, PostgreSQL 18 documentation](https://www.postgresql.org/docs/current/sql-insert.html) — validated that `ON CONFLICT DO NOTHING` skips a proposed row when a usable unique constraint or index reports a conflict.
