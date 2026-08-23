# BurstLab on One Machine

**Status:** complete
**Managed updates:** authorized
**Version:** 1.0
**Validated:** authoritative sources checked 23 August 2026; standalone course and current lab artifacts audited; target execution remains pending
**Relevant versions:** Go 1.27.0 recommended on the target (`go.mod` language floor 1.25.0); NATS Server 2.14.5; nats.go 1.53.1; NATS CLI 0.4.0; PostgreSQL image 18.6-bookworm; pgx 5.10.0; k6 2.2.0
**Execution check:** current-source unit/race tests, vet, Compose/k6/shell validation, API/queue/worker/PostgreSQL integration, NUL defense/quarantine, frozen evidence, and a shortened functional confirmation passed on a smaller WSL2 host. That proves the required path can work; it is not a capacity result. No RPS has yet been measured on the separate 10-core/32-GB target.

## Course contract

- **Goal:** Build, operate, diagnose, and benchmark a queue-backed ingestion system on one Linux machine before mapping the same relationships to AWS.
- **End result:** You can run a Go API, durable local queue, worker, PostgreSQL, and co-located open-model load generator; find the highest tested burst-acceptance and end-to-end sustainable rates under a frozen 10-core/32-GB configuration; measure the worker/PostgreSQL pipeline drain rate or establish a resolution-bounded lower limit; reconcile accepted events with durable state; and explain every claim's limits.
- **Starting assumptions:** A separate Ubuntu 24.04 x86-64 target with exactly 10 logical CPUs, 32 GB installed RAM, SSD or NVMe storage, Docker Engine with Compose, and permission to run local synthetic load. Basic terminal use is assumed; prior Go, NATS, PostgreSQL, Docker, and load-testing expertise is not.
- **Not covered:** AWS deployment or Terraform, performance equivalence between NATS JetStream and SQS, public-network or TLS capacity, production identity, backups, multi-host scaling, high availability, chaos engineering, or long-duration capacity.
- **Scale:** Approximately 4–6 hours plus machine-dependent confirmation and drain time. The separate course speedrun is an orientation under two hours, not a mastery claim.
- **Teaching scaffold limits:** All traffic and data are local and synthetic. The benchmark includes contention from the API, worker, queue, database, Docker daemon, monitoring, and load generator on one host. Every RPS statement is bounded by the recorded machine, versions, configuration, data, duration, and pass criteria.

## Source relationship

This is a local precursor to [`burstlab_15k_aws_beginner_course.md`](../../burstlab_15k_aws_beginner_course.md). The supplied AWS course remains read-only. This course preserves its two data-safety invariants while substituting local components; it neither validates nor predicts the AWS course's result.

## How to use this course

Run the modules in order. Do not begin capacity discovery until the correctness gate passes. Keep API and worker logs visible, save every generated result, and change one benchmark variable at a time. A failed run is evidence; do not delete it or quietly rerun under different settings.

To resume, start at the first module whose completion evidence is missing. Reload `.env`, re-prove the current Compose/native process/queue state, and reuse any recorded manual run ID. After a reboot or tool change, rerun preflight. If accepted work or synthetic state is uncertain, preserve evidence and either drain/reconcile it or perform the guarded clean reset before continuing; never guess the resume state.

Each live action uses this contract:

- **Before:** conditions that must already be true.
- **Do:** the exact action.
- **Expect:** the observation that supports the model.
- **If different:** what the different result means.
- **Recover or stop:** the safe next move.
- **Evidence:** what proves completion.

| Module | Typical active time | Completion evidence |
|---|---:|---|
| 1. Freeze the machine | 20–40 min | passing target preflight |
| 2. Build the whole | 35–50 min | healthy dependencies, native API and worker |
| 3. Prove correctness | 40–60 min | auth, validation, 202 boundary, dedupe, quarantine |
| 4. Prove recovery | 20–30 min | stopped-worker backlog drains to one DB row |
| 5. Calibrate k6 | 25–40 min | health profile reaches candidate rate with zero drops |
| 6. Discover the bracket | 30–90 min | last pass and first fail recorded |
| 7. Confirm and measure | 60+ min | repeatable trials and a drain probe |
| 8. Interpret and bridge | 30–45 min | bounded report and causal explanation |

## The finished whole first

```text
co-located k6
     |
     v
127.0.0.1 Go HTTP API
     | authenticate + validate
     | synchronous JetStream publish
     v
file-backed EVENTS work queue on local NATS
     | durable pull consumer, explicit ack
     v
native Go worker
     | transaction: COPY stage -> INSERT ON CONFLICT -> COMMIT
     v
PostgreSQL events table
     |
     +---- only after commit ----> queue ACK + flush
```

One request moves through five distinct states:

1. **Rejected:** authentication, JSON, or field validation failed; it must not enter the queue.
2. **Accepted:** the API received a synchronous JetStream `PubAck` and returned HTTP `202`.
3. **Queued:** the stream retains it until the durable consumer acknowledges it.
4. **Committed:** the database transaction completed, possibly suppressing a duplicate.
5. **Acknowledged:** the worker sent the queue ack after commit and flushed the NATS connection.

The two invariants are the spine of the course:

```text
No durable queue acknowledgement -> no HTTP 202
No database commit               -> no queue acknowledgement
```

A `PubAck` proves stream acceptance, not business completion. JetStream's acknowledged-consumer loop can redeliver, so the database primary key `(tenant_id, request_id)` makes retries safe. The whole pipeline is at-least-once plus idempotency; do not call it exactly-once. [NATS publishing](https://docs.nats.io/learn/jetstream/publishing) distinguishes storage acknowledgement from consumer processing, and [delivery and acknowledgement](https://docs.nats.io/learn/jetstream/delivery-and-acknowledgment) documents redelivery when an ack does not arrive.

### Why selective Docker

NATS and PostgreSQL are stateful dependencies with useful official images and named volumes, so Compose owns them. The API, worker, and k6 run natively to avoid adding a build image and a container network hop to the paths being studied. Linux host networking avoids NAT and a userland proxy, but it also shares the host network namespace; the service configurations therefore bind `127.0.0.1` explicitly. [Docker documents both properties](https://docs.docker.com/engine/network/drivers/host/).

### The honest durability boundary

The lab uses one file-backed NATS server, one replica, an 8-GiB stream limit, `DiscardNew`, and `sync_interval: always`. NATS documents that its default file-store sync interval can leave recently acknowledged work vulnerable to an OS or power failure; `always` requests an `fsync` before every acknowledgement and trades substantial performance for the stronger local-disk boundary. One replica still cannot survive loss or outage of its only server or disk. When the 8-GiB limit is reached, `DiscardNew` rejects the new publish; the API must return `503`, not `202`. [JetStream's storage documentation](https://github.com/nats-io/nats.docs/blob/master/nats-concepts/jetstream/README.md#syncing-data-to-disk) states these limits.

## Safety, privacy, and cleanup before you begin

- Use synthetic values only. Request bodies, rejected queue payloads, process logs, and result files are not designed for personal or confidential data.
- The token and database password in `.env.example` are weak course credentials. Never reuse them elsewhere.
- The API, NATS client port, NATS unauthenticated monitoring port, and PostgreSQL all bind loopback. Stop if `ss -ltnp` shows them exposed on `0.0.0.0` or `::`.
- PostgreSQL uses `sslmode=disable` only because both client and server are on the same host and loopback. This is not a production setting.
- `scripts/reset-lab.sh --yes` irreversibly purges the synthetic stream and truncates both course tables. Stop the API and worker first. The lab has no backup.
- `docker compose down` stops containers but retains named volumes. This course deliberately does not give a `down -v` command.
- Do not drop Linux caches, alter kernel limits, overclock, or add database/NATS tuning during the baseline. Those create a different benchmark.
- Do not publish a result from `ALLOW_NON_TARGET=1`; that flag exists only for a labeled functional check.

NATS monitoring is plain, unauthenticated HTTP by default, which is why port 8222 stays on loopback. The official [monitoring endpoint guide](https://docs.nats.io/learn/monitoring/monitoring-endpoints) describes `/varz`, `/jsz`, and this exposure boundary.

## Course map

| Module | Capability built | Gate before moving on |
|---|---|---|
| 1 | Identify and freeze the exact host/tool shape | preflight says target matches |
| 2 | Trace and operate the whole local system | both containers healthy; API and worker connected |
| 3 | Prove auth, validation, durable-202, commit, dedupe, quarantine | all correctness observations match |
| 4 | Diagnose backlog and recovery | stopped-worker event appears after restart, once |
| 5 | Explain open load and calibrate the co-located generator | candidate health load has zero drops |
| 6 | Find a pass/fail bracket without guessing 15K | last pass and first fail have evidence |
| 7 | Confirm burst, sustainable, and drain rates | three trials per claimed rate reconcile |
| 8 | State what was learned and what remains unknown | report includes boundaries and failure evidence |

# Module 1 — Freeze the target and tools

## Outcome

You will determine whether the separate machine is the declared 10-logical-CPU, 32-GB Ubuntu target and capture the software/storage identity needed to reproduce later numbers.

## Mental model

RPS is not a property of Go source alone. It is an observation of a system shape: CPU topology, memory, storage and filesystem, kernel, Docker allocation, component builds, co-located work, data volume, load profile, and pass rule. Change any of them and the comparison needs a new label.

**Worked example:** “9,800 RPS” is not useful. “Highest target whose three ten-minute holds passed on the recorded 10-CPU/32-GB host, with zero drops, failure below 0.5%, p95 below 150 ms, and full reconciliation” is auditable.

## Guided action 1.1 — Enter the lab and create local configuration

**Before:** The repository is copied to the separate target and the terminal is inside its Git worktree. No course service is running.

**Do:**

```bash
cd "$(git rev-parse --show-toplevel)"
cd labs/burstlab-single-machine
if [[ ! -e .env ]]; then cp .env.example .env; else echo '.env already exists; kept it'; fi
set -a
source .env
set +a
```

Read `.env`. Keep `HTTP_ADDR`, `URL`, `NATS_URL`, and `DATABASE_URL` on `127.0.0.1`.

**Expect:** `pwd` ends in `labs/burstlab-single-machine`; `.env` contains only synthetic local settings.

**If different:** You are in the wrong checkout, or an earlier `.env` may describe a different system.

**Recover or stop:** Find the correct repository root. If `.env` existed, compare it with `.env.example`; do not overwrite unexplained settings.

**Evidence:** Record `git rev-parse HEAD`. If the worktree has course changes, also record `git status --short` and archive the exact non-secret lab files.

## Guided action 1.2 — Install and verify prerequisites

Use trusted official instructions for [Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Go](https://go.dev/doc/install), [k6](https://grafana.com/docs/k6/latest/set-up/install-k6/), and the [NATS CLI](https://github.com/nats-io/natscli/releases/tag/v0.4.0). Install Go 1.27.0 and k6 2.2.0 for the reference result, or record a deliberate deviation. The module keeps a Go 1.25 language floor; the target should use a supported toolchain. [Go's release history](https://go.dev/doc/devel/release) is the version authority.

**Before:** Installation is permitted, and you know whether Docker commands require local `docker` group membership.

**Do:**

```bash
go version
k6 version
nats --version
docker version
docker compose version
```

**Expect:** Every command succeeds; the reference versions appear in this document's metadata.

**If different:** A missing command is a prerequisite failure. A later version is not automatically invalid, but it defines a different benchmark.

**Recover or stop:** Install from the official source, restart the shell if group membership changed, and rerun all commands. Do not alias a different load tool as `k6`.

**Evidence:** The next action's preflight report captures the actual versions.

## Guided action 1.3 — Run the target preflight

**Before:** `.env` is loaded, Docker is running, and ports 4222, 5432, 8080, and 8222 should be unused.

**Do:**

```bash
bash scripts/preflight.sh
```

**Expect:** The `Result` section contains `PASS`. The report's final line gives its path. It shows Ubuntu 24.04, x86-64, exactly 10 logical CPUs, at least 30 GiB visible RAM, disk identity, filesystems, Docker resources/root, open-file limit, and tool versions.

**If different:** `MISSING` means a required command or Docker capability is unavailable. `TARGET MISMATCH` means this is not the result machine. The script records but does not automatically reject rotating Docker storage, a Docker CPU/memory limit, low disk, background load, virtualization, or thermal throttling; those are manual stop gates.

**Recover or stop:** Fix missing tools or ports. Confirm Docker sees all 10 CPUs and roughly 32 GB, and that the Docker root is backed by the declared SSD/NVMe. For a rehearsal only, run `ALLOW_NON_TARGET=1 bash scripts/preflight.sh` and label every result non-target.

**Evidence:** Keep `results/preflight-*.txt`. Add the storage model, Docker-root device/filesystem, CPU model, kernel, power/virtualization facts, ambient load, and free disk to the report.

## Less-guided check

Explain why two nominally “10-core, 32-GB” machines can differ. Name storage latency, logical versus physical cores, thermal/power policy, virtualization, Docker limits, and co-located work.

**Completion evidence:** A passing target preflight and a frozen-host description. Otherwise Module 1 is incomplete.

**Optional depth:** Read `scripts/preflight.sh` and identify which facts it enforces, merely records, and cannot see.

# Module 2 — Build and operate the finished whole

## Outcome

You will start only the stateful dependencies in Docker, build one native Go binary, and run its worker and API modes in separate terminals.

## Mental model

The queue decouples acceptance from database completion. It does not create capacity: if accepted work stays above the worker/database rate, backlog grows until the stream limit rejects publishes. The queue changes *when* pressure is handled and gives recovery time; it does not erase work.

**Worked example:** With the worker stopped, a valid request can receive `202` because its durable destination is the queue, not the database. Its row appears after the worker returns.

## Guided action 2.1 — Start stateful dependencies

**Before:** Module 1 passed; no process owns ports 4222, 5432, or 8222; `.env` is loaded.

**Do:**

```bash
docker compose config --quiet
docker compose pull
docker compose up -d --wait
docker compose ps
```

**Expect:** `nats` and `postgres` are `healthy`. The exact tags are NATS 2.14.5 Alpine 3.22 and PostgreSQL 18.6 Bookworm.

**If different:** Likely causes are a port collision, unsupported host networking, invalid NATS config, failed image pull, or incompatible PostgreSQL volume.

**Recover or stop:** Run `docker compose logs --tail=100 nats postgres` and `ss -ltnp`. Correct the named fault. `docker compose down` safely stops containers and retains data; do not delete volumes to hide an unexplained failure.

**Evidence:** Save `docker compose ps`, exact tags, and target-resolved image IDs/repository digests. Tags can move; digests identify what ran.

## Guided action 2.2 — Test and build the native program

**Before:** A supported Go toolchain is active and dependencies are unchanged.

**Do:**

```bash
go test ./...
go build -o burstlab .
```

**Expect:** Tests pass and `./burstlab` exists. Unit tests cover authentication, strict/oversized JSON and NUL rejection, the handler's publish-ack requirement, queue-envelope classification, and the non-expiring/unlimited-redelivery JetStream contract. They do not alone prove the runtime commit-before-ack path; later code tracing and failure exercises do that.

**If different:** A compile or test failure is a correctness failure, not a performance result.

**Recover or stop:** Read the first error, verify `go.mod` and `go.sum`, and fix only the identified cause. Do not benchmark failing code.

**Evidence:** Store `go version`, test output, `go.mod`, `go.sum`, and a SHA-256 of the binary.

## Guided action 2.3 — Start the worker in terminal W

**Before:** NATS and PostgreSQL are healthy; the binary was just built.

**Do in terminal W:**

```bash
cd "$(git rev-parse --show-toplevel)/labs/burstlab-single-machine"
set -a; source .env; set +a
BURSTLAB_MODE=worker ./burstlab
```

**Expect:** `worker started`. It creates tables, validates or creates stream `EVENTS`, and attaches durable consumer `burstlab-worker`.

**If different:** Database/NATS connection or stream/consumer-contract validation failed. A pre-existing stream with different retention, storage, replicas, size, subject, discard, expiry, or publish-ack policy is rejected. So is a consumer that can skip old work, stop redelivering, use a different ack policy/timeout/filter, or hold a different outstanding-ack limit.

**Recover or stop:** Keep the error. Check `docker compose ps`, logs, `.env`, and `nats stream info EVENTS`. Do not benchmark through a mismatch.

**Evidence:** Visible `worker started` plus `nats consumer info EVENTS burstlab-worker` succeeding.

## Guided action 2.4 — Start the API in terminal A

**Before:** Terminal W remains healthy.

**Do in terminal A:**

```bash
cd "$(git rev-parse --show-toplevel)/labs/burstlab-single-machine"
set -a; source .env; set +a
BURSTLAB_MODE=api ./burstlab
```

**Expect:** `api listening on 127.0.0.1:8080`.

**If different:** Port 8080 is occupied, the token digest is malformed, NATS is unreachable, or the stream differs.

**Recover or stop:** Inspect `ss -ltnp`, `.env`, and the first API error. Keep loopback binding.

**Evidence:** In a control terminal:

```bash
curl -i --max-time 2 http://127.0.0.1:8080/health/ready
curl -fsS --max-time 2 http://127.0.0.1:8222/connz | grep -E 'burstlab-(api|worker)'
```

The first response must be `200`; both native clients must appear. `/health/ready` proves the API currently has a NATS transport connection, not that the next disk persistence will succeed.

## Less-guided check

Locate the `202`, synchronous `js.Publish`, database `tx.Commit`, and message `Ack` in `main.go`. Put them in causal order and explain the loss caused by reversing either middle relationship.

**Completion evidence:** Healthy dependencies, passing tests, a built binary, ready API, and connected worker.

**Optional depth:** Explain why `network_mode: host` makes the explicit `127.0.0.1` binds security-relevant.

# Module 3 — Pass the correctness gate

## Outcome

You will prove rejection behavior, the durable acceptance boundary, duplicate safety, malformed-message quarantine, and reconciliation before meaningful load.

## Mental model

Performance amplifies behavior. A fast endpoint returning `202` before durable storage is a faster data-loss bug. Correct state transitions are admission criteria for capacity work.

**Worked example:** If NATS is unavailable, a correct API becomes slower or returns `503`; an incorrect API can look fast by returning `202` for work that vanished. Only the first behavior is eligible for benchmarking.

## Guided action 3.1 — Run one-event smoke

**Before:** API, worker, NATS, and PostgreSQL run; `.env` is loaded.

**Do:**

```bash
export MANUAL_RUN="m$(date -u +%Y%m%dT%H%M%S)"
printf 'manual_run=%s\n' "$MANUAL_RUN" | tee "results/${MANUAL_RUN}-manual-id.txt"
bash scripts/run-benchmark.sh smoke 1
```

**Expect:** One request, one `202`, one accepted event, no failure, zero exit. The wrapper writes before/after evidence, log, traces, and JSON summary under `results/` and prints a unique run ID.

**If different:** The wrapper may identify a missing ready API, durable consumer, or connected worker. A k6 failure means the one request broke the contract.

**Recover or stop:** Inspect terminals A/W and the run's log/evidence. Resolve correctness before increasing load.

**Evidence:** Keep all files sharing the smoke run ID and use the wrapper's printed drained-capture command after backlog reaches zero. Keep `MANUAL_RUN` exported through Modules 3–4; if you resume in a new shell, restore its exact recorded value rather than reusing a static request ID.

## Guided action 3.2 — Prove auth and strict input

**Before:** Smoke passed.

**Do:**

```bash
event_ts=$(date -u +%FT%TZ)
curl -i --max-time 3 \
  -H 'Authorization: Bearer wrong' \
  -H 'Content-Type: application/json' \
  --data "{\"request_id\":\"${MANUAL_RUN}-auth-one\",\"event_ts\":\"$event_ts\",\"value\":\"synthetic\"}" \
  http://127.0.0.1:8080/v1/events

curl -i --max-time 3 \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"request_id":"bad json"}' \
  http://127.0.0.1:8080/v1/events

curl -i --max-time 3 \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data "{\"request_id\":\"${MANUAL_RUN}-nul-one\",\"event_ts\":\"$event_ts\",\"value\":\"\\u0000\"}" \
  http://127.0.0.1:8080/v1/events
```

**Expect:** Wrong token is `401`; unsupported/incomplete input and a PostgreSQL-incompatible NUL value are `400`; none creates an event.

**If different:** `202` is a correctness/security failure. `503` means queue unavailability rather than accepted input.

**Recover or stop:** Stop load work, inspect API log and `/stats`, rerun tests, and restore supplied code/config.

**Evidence:** Save responses and show `RUN_ID="${MANUAL_RUN}-auth" BURSTLAB_MODE=count ./burstlab` reports zero matching events.

## Guided action 3.3 — Prove queue failure cannot return 202

**Before:** Terminals A/W are visible and idle. This interrupts only local NATS.

**Do:**

```bash
docker compose stop nats
event_ts=$(date -u +%FT%TZ)
curl -i --max-time 5 \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data "{\"request_id\":\"${MANUAL_RUN}-queue-down-one\",\"event_ts\":\"$event_ts\",\"value\":\"synthetic\"}" \
  http://127.0.0.1:8080/v1/events
```

**Expect:** `503 Service Unavailable`, possibly after the two-second publish timeout; never `202`. A failed or lost `PubAck` can be an ambiguous publish outcome, so `503` does not itself prove the message is absent.

**If different:** `202` violates invariant one. A connection error means the API also stopped and does not test the boundary.

**Recover or stop:** Restore NATS and wait for transport readiness:

```bash
docker compose start nats
until curl -fsS --max-time 2 http://127.0.0.1:8222/healthz >/dev/null; do sleep 1; done
until curl -fsS --max-time 2 http://127.0.0.1:8080/health/ready >/dev/null; do sleep 1; done
```

If either loop fails to recover promptly, press `Ctrl-C`, inspect logs, and stop.

**Evidence:** Preserve the `503` and API error counter. After recovery, use `RUN_ID="${MANUAL_RUN}-queue-down" BURSTLAB_MODE=count ./burstlab` to record whether the event exists. If a caller retries an ambiguous attempt, it must reuse the same request ID so database idempotency keeps at most one effect.

## Guided action 3.4 — Prove database idempotency

**Before:** NATS is ready and terminal W reconnected without errors.

**Do:**

```bash
for attempt in 1 2; do
  event_ts=$(date -u +%FT%TZ)
  curl -sS -o /dev/null -w "attempt=$attempt status=%{http_code}\n" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"request_id\":\"${MANUAL_RUN}-duplicate-one\",\"event_ts\":\"$event_ts\",\"value\":\"synthetic\"}" \
    http://127.0.0.1:8080/v1/events
done
for second in {1..30}; do
  duplicate_counts=$(RUN_ID="${MANUAL_RUN}-duplicate" BURSTLAB_MODE=count ./burstlab)
  printf '%s\n' "$duplicate_counts"
  grep -q '"events":1' <<<"$duplicate_counts" && break
  sleep 1
done
if ! grep -q '"events":1' <<<"$duplicate_counts"; then
  nats --server "$NATS_URL" consumer info EVENTS burstlab-worker
  echo 'STOP: duplicate result did not commit within 30 seconds' >&2
  exit 1
fi
```

**Expect:** Both calls return `202`, but exactly one row remains. Duplicate HTTP requests consume queue capacity; dedupe is downstream. `accepted_at` is database insertion time, not HTTP acceptance time.

**If different:** Zero can be a normal transient before the asynchronous worker commits; it fails only after the bounded poll. Two rows means the composite key is broken.

**Recover or stop:** Check worker errors and consumer state. Do not loosen the key.

**Evidence:** Two `202`s, one matching row, and an increased worker duplicate counter in terminal W.

## Guided action 3.5 — Prove quarantine

**Before:** Worker connected; quarantine count known.

**Do:**

```bash
before_quarantine_counts=$(BURSTLAB_MODE=count ./burstlab)
before_quarantine=$(sed -n 's/.*"quarantine":\([0-9][0-9]*\).*/\1/p' <<<"$before_quarantine_counts")
nats --server "$NATS_URL" pub events.ingest 'not-json'
quarantine_done=0
for second in {1..30}; do
  quarantine_counts=$(BURSTLAB_MODE=count ./burstlab)
  after_quarantine=$(sed -n 's/.*"quarantine":\([0-9][0-9]*\).*/\1/p' <<<"$quarantine_counts")
  consumer_state=$(nats --server "$NATS_URL" consumer info EVENTS burstlab-worker --json)
  printf '%s\n%s\n' "$quarantine_counts" "$consumer_state"
  if [[ $after_quarantine -eq $((before_quarantine + 1)) ]] &&
     grep -Eq '"num_pending"[[:space:]]*:[[:space:]]*0' <<<"$consumer_state" &&
     grep -Eq '"num_ack_pending"[[:space:]]*:[[:space:]]*0' <<<"$consumer_state"; then
    quarantine_done=1
    break
  fi
  sleep 1
done
if (( quarantine_done == 0 )); then
  echo 'STOP: malformed message did not quarantine and drain within 30 seconds' >&2
  exit 1
fi
```

**Expect:** Global quarantine count increases by one; event count does not. Worker commits quarantine before ack. The quarantine row is unique by JetStream stream sequence, so redelivery after commit cannot create a second row for the same poison message.

**If different:** Pending means not handled yet. Ack with no quarantine increment would violate invariant two for malformed data.

**Recover or stop:** Inspect terminal W and pending/ack-pending. Preserve payload and state; do not purge to manufacture a pass.

**Evidence:** Before/after quarantine delta and worker counter. Direct NATS publication tests worker defense, not authenticated API behavior. Direct envelopes also have a narrower validation contract than API input; do not use this path for normal load.

## Less-guided check

Describe wrong token, invalid body, full `DiscardNew` stream, and repeated request ID. Include HTTP/database effects and whether a queue message can exist.

**Completion evidence:** Smoke plus all correctness observations match.

**Optional depth:** Inspect the 1-KiB body limit, unknown-field rejection, ±24-hour API timestamp window, request-ID alphabet, 256-byte value limit, fixed tenant, and constant-time token comparison.

# Module 4 — Prove decoupling and recovery

## Outcome

You will stop the worker, observe accepted backlog, restart it, and prove one database effect.

## Mental model

With an explicit-ack durable consumer, delivery and completion differ. Without a worker, `num_pending` rises. After delivery but before ack, `num_ack_pending` can rise and redelivery can occur after `AckWait`. Commit-before-ack plus the unique key makes both paths converge.

**Worked example:** A worker commits `paused-one` and crashes before its ack reaches NATS. Redelivery tries the same row again; the primary key suppresses a second effect, after which the retry can be acknowledged.

## Guided action 4.1 — Accept while worker is stopped

**Before:** Correctness passed; queue counts are zero; API remains running.

**Do:** Press `Ctrl-C` in terminal W, then:

```bash
event_ts=$(date -u +%FT%TZ)
curl -sS -o /dev/null -w 'status=%{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  --data "{\"request_id\":\"${MANUAL_RUN}-paused-one\",\"event_ts\":\"$event_ts\",\"value\":\"synthetic\"}" \
  http://127.0.0.1:8080/v1/events
nats --server "$NATS_URL" consumer info EVENTS burstlab-worker
RUN_ID="${MANUAL_RUN}-paused" BURSTLAB_MODE=count ./burstlab
```

**Expect:** HTTP `202`; pending at least one; matching DB count zero.

**If different:** `503` means queue acceptance failed. A row means worker was not stopped or the ID existed.

**Recover or stop:** Preserve state, choose a new ID, and repeat only after `/connz` proves no worker connection.

**Evidence:** `202`, pending state, absent worker connection, zero rows.

## Guided action 4.2 — Restart and drain

**Before:** `${MANUAL_RUN}-paused-one` is pending.

**Do:** Restart the worker with action 2.3, then use a bounded poll:

```bash
paused_drained=0
for second in {1..30}; do
  paused_counts=$(RUN_ID="${MANUAL_RUN}-paused" BURSTLAB_MODE=count ./burstlab)
  consumer_state=$(nats --server "$NATS_URL" consumer info EVENTS burstlab-worker --json)
  printf '%s\n%s\n' "$paused_counts" "$consumer_state"
  if grep -q '"events":1' <<<"$paused_counts" &&
     grep -Eq '"num_pending"[[:space:]]*:[[:space:]]*0' <<<"$consumer_state" &&
     grep -Eq '"num_ack_pending"[[:space:]]*:[[:space:]]*0' <<<"$consumer_state"; then
    paused_drained=1
    break
  fi
  sleep 1
done
if (( paused_drained == 0 )); then
  echo 'STOP: stopped-worker event did not drain within 30 seconds' >&2
  exit 1
fi
```

**Expect:** Row becomes one; pending and ack-pending become zero.

**If different:** Persistent pending indicates processing failure; more than one row means broken idempotency; persistent ack-pending suggests ack/flush trouble.

**Recover or stop:** Keep the queue, inspect terminal W and dependency health, and repair processing. Never purge accepted work as recovery.

**Evidence:** Before/after queue state and one row.

## Less-guided check

Trace normal and stopped-worker paths through the five states. Explain crashes before commit, after commit/before ack, and after ack.

**Completion evidence:** The stopped-worker event drains to one row and zero backlog.

**Optional depth:** Read `AckWait`, `MaxAckPending`, batch size/window, staging `COPY`, and `ON CONFLICT`; predict their memory, latency, and retry effects.

# Module 5 — Calibrate a co-located open-model generator

## Outcome

You will understand the tool choice, verify the script, and prove the generator/liveness path can schedule each candidate before event load.

## Mental model

A closed model waits for completion before a virtual user starts again, so server slowdown can reduce offered load. k6 arrival-rate executors use an open model: starts are scheduled independently. That fits target-RPS tests only when enough VUs and generator CPU exist. [k6 explains the distinction](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/open-vs-closed/).

`dropped_iterations` is work k6 intended but could not start. It may mean too few VUs, generator constraint, or a slow system. Zero is necessary to claim scheduled target load, not sufficient to prove server capacity. See [VU allocation](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/arrival-rate-vu-allocation/) and [dropped iterations](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/dropped-iterations/).

**Worked example:** At a 1,000-RPS target, 50 drops mean the system received less than the promised schedule even if every sent request returned `202`. The trial cannot substantiate 1,000 RPS.

| Profile | Shape | Purpose |
|---|---|---|
| `smoke` | one iteration | correctness wiring |
| `health` | 30-second constant open arrival | k6 + Go liveness path; no JSON/auth/NATS/DB |
| `discovery` | 30-second constant open arrival | cheap bracketing |
| `confirmation` | 2-minute low, 3-minute ramp, 10-minute hold | final measured trial |

Hold-tagged confirmation metrics decide latency/error acceptance. Zero drops applies to the full confirmation. [k6 thresholds](https://grafana.com/docs/k6/latest/using-k6/thresholds/) are executable pass/fail criteria.

## Tool choice

- **k6 primary:** open arrival rates, tagged phases, thresholds, dropped visibility, and JSON summary fit the claim.
- **Vegeta optional diagnostic:** useful only as a separately labeled constant-rate check if k6 seems generator-bound; it cannot silently replace k6 evidence.
- **hey smoke-only:** convenient concurrent probe, not the authoritative schedule.
- **Bombardier omitted:** another concurrency-oriented probe adds a dependency without improving this evidence.

## Guided action 5.1 — Validate the k6 program

**Before:** Module 4 passed; API/worker run; `.env` loaded.

**Do:**

```bash
RUN_ID=inspect PROFILE=smoke \
  k6 --config k6-config.json inspect --include-system-env-vars load.js
```

**Expect:** k6 parses one smoke scenario and thresholds.

**If different:** k6 version, environment, or JavaScript is incompatible.

**Recover or stop:** Verify k6 2.2.0, `TOKEN`, and untouched `load.js`.

**Evidence:** Inspect output and exact `load.js`.

## Guided action 5.2 — Initial health calibration

**Before:** Host idle; smoke passed. Health targets `/health/live` and bypasses the event path.

**Do:**

```bash
bash scripts/run-benchmark.sh health 100
```

**Expect:** Roughly 100 requests/s for 30 seconds, p95 below 150 ms, failures below 0.5%, zero drops.

**If different:** Drops point first to VUs or co-located scheduling; high latency without drops points to host/API contention; failures require logs.

**Recover or stop:** Do not run events at 100. Inspect CPU/VUs. Increase `PRE_ALLOCATED_VUS` in `.env` to cover roughly `target RPS × response seconds` plus variance and set `MAX_VUS` equal, preventing allocation during measurement. Rerun. If it still drops, lower target or run a separately labeled Vegeta diagnostic.

**Evidence:** Passing health summary and exact VU settings.

## Guided action 5.3 — Calibrate each serious candidate

**Before:** A proposed event rate exceeds the most recent passing health calibration; API runs and the host is otherwise in its frozen state.

**Do:**

```bash
CANDIDATE_RPS=200
bash scripts/run-benchmark.sh health "$CANDIDATE_RPS"
```

Set `CANDIDATE_RPS` to the actual proposed rate and keep the same VU allocation used for the event run.

**Expect:** Health reaches that rate with zero drops and the configured HTTP thresholds pass. This bounds co-located k6 plus Go HTTP/liveness; it does not certify JSON, auth, NATS, or DB capacity.

**If different:** The candidate's single-machine k6 claim is invalid even if an event run happens to look good.

**Recover or stop:** Tune only up-front VUs, retest, or lower the target. Moving k6 elsewhere answers a different question.

**Evidence:** Pair every claimed event rate with a same-rate passing health result.

For every wrapper run, `results/<run-id>-benchmark.env` freezes the effective load profile plus non-secret service/image/Compose/Docker identities and source/config fingerprints. The wrapper rejects ambient `K6_*` overrides and always uses the committed empty `k6-config.json`; before/after/drained snapshots read the same manifest instead of silently adopting a later `.env` change. Keep the manifest with the summary and do not edit it. All three snapshots must show the same manifest SHA-256 and `configuration_integrity=match`; otherwise the run is inconclusive.

## Less-guided check

Explain why zero drops and p95 below 150 ms answer different questions, and why k6 CPU is part of this contract.

**Completion evidence:** Inspect passes and health reaches the next candidate with zero drops.

**Optional depth:** Identify `phase` tags and `handleSummary()` in `load.js`. [Custom summary docs](https://grafana.com/docs/k6/latest/results-output/end-of-test/custom-summary/) describe the output lifecycle.

# Module 6 — Discover burst and sustainable brackets

## Outcome

You will find last pass and first fail without assuming the machine reaches 15K RPS.

## Mental model

Capacity discovery is a bounded search, not a dare. Short runs find the neighborhood cheaply; fixed confirmations establish the claim. The first failure above a pass is as important as the pass because it bounds what was actually tested.

**Worked example:** If 800 passes, 1,600 fails, 1,200 fails, 1,000 passes, and 1,100 fails, the discovery bracket is 1,000–1,100 RPS. It is not evidence that 1,099 passes or that 1,100 always fails.

## Three rates, three questions

1. **Burst acceptance RPS:** hold `202` count divided by hold seconds at the highest tested target satisfying HTTP criteria. Backlog may grow, but accepted work must drain/reconcile within 30 minutes.
2. **Sustainable end-to-end RPS:** highest tested hold rate satisfying HTTP criteria while the worker/database keeps backlog from growing and returns it to zero within 60 seconds after load.
3. **Worker/PostgreSQL pipeline drain rate:** run-specific rows committed per second while draining a controlled backlog after generation stops. It includes NATS delivery/ack and is not sustainable ingress.

Always report scheduled target, attempted HTTP RPS, and accepted-202 RPS separately. Attempted RPS counts HTTP requests k6 actually issued/completed; dropped iterations were scheduled work that never became requests. Reconcile the DB against `accepted_total` across low, ramp, and hold—not only hold accepts.

## Candidate pass rules

| Rule | Burst | Sustainable |
|---|---:|---:|
| requested hold scheduled | required | required |
| dropped iterations | exactly 0 over full run | exactly 0 over full run |
| hold `202` check rate | `> 0.995` | `> 0.995` |
| hold failure rate | `< 0.005` | `< 0.005` |
| hold p95 | `< 150 ms` | `< 150 ms` |
| connected workers in trace | exactly 1 throughout | exactly 1 throughout |
| frozen evidence identity | same manifest SHA; integrity `match` | same manifest SHA; integrity `match` |
| accepted-total / run rows after drain | equal | equal |
| quarantine delta | 0 | 0 |
| backlog during hold | may grow | no sustained growth |
| final drain | zero within 30 min | zero within 60 s |

Backlog `B = num_pending + num_ack_pending`. For a repeatable sustainable decision, record `B` at hold start/end. Allow one batch of endpoint sampling noise: `B_end <= B_start + 1000`. To avoid false failure from the same batch sawtooth, allow a least-squares slope no greater than one batch divided by the hold: `1000 / 600 = 1.667 events/s` under defaults. Also require zero within 60 seconds. If observations disagree, fail or mark inconclusive.

The wrapper enforces k6 thresholds only. You decide queue trend, drain, reconciliation, quarantine delta, host pressure, OOM/restarts, disk pressure, and repeatability.

## Guided action 6.1 — Establish a clean measured-series state

**Before:** Archive correctness evidence; account for every accepted event; stop API and worker with `Ctrl-C`; prove no native client traffic; dependencies remain healthy; only synthetic data is in scope.

**Do:**

```bash
if curl -fsS --max-time 2 http://127.0.0.1:8222/connz | \
  grep -Eq 'burstlab-(api|worker)'; then
  echo 'STOP: a native course client is still connected' >&2
  exit 1
fi
bash scripts/reset-lab.sh --yes
BURSTLAB_MODE=count ./burstlab
nats --server "$NATS_URL" stream info EVENTS
```

After both independent zero checks pass, restart the normal path. In terminal W, run action 2.3; in terminal A, run action 2.4. Then, from the control terminal, require readiness and exactly one connection for each native client:

```bash
curl -fsS --max-time 2 http://127.0.0.1:8080/health/ready
for client in burstlab-worker burstlab-api; do
  connections=$(curl -fsS --max-time 2 http://127.0.0.1:8222/connz | \
    grep -Eo "\"name\"[[:space:]]*:[[:space:]]*\"${client}\"" | wc -l)
  if [[ "$connections" -ne 1 ]]; then
    echo "STOP: expected one $client connection, found $connections" >&2
    exit 1
  fi
done
```

**Expect:** Before restart, the count JSON shows zero events/total/quarantine and stream messages are zero. After restart, readiness succeeds, exactly one API and one worker connection exist, and named volumes remain.

**If different:** The script refuses non-loopback, missing, or unreachable stores. Queue purge and DB truncate cannot be one cross-system transaction, so a later failure can leave partial reset state.

**Recover or stop:** Inspect both stores. Restore reachability, rerun the guarded reset, then independently prove zero queue messages, event rows, and quarantine rows. Restart worker/API using Module 2 and prove ready/connected.

**Evidence:** Reset output, independently verified zeros, and fresh native start logs.

## Guided action 6.2 — Start low

`sync_interval: always` is durability-heavy, so begin at 100 RPS rather than importing 15K.

**Before:** Correctness/health pass; both native clients connected; backlog zero; host quiet; adequate disk.

**Do:**

```bash
bash scripts/run-benchmark.sh discovery 100
```

Copy the printed run ID, then use the frozen-endpoint waiter and enforce the 30-minute deadline from k6 exit:

```bash
LAST_RUN=replace-with-the-printed-run-id
bash scripts/wait-for-drain.sh "$LAST_RUN" 1800
load_end_epoch=$(date -u -d "$(<"results/${LAST_RUN}-load-end.utc")" +%s)
drain_end_epoch=$(<"results/${LAST_RUN}-drain-end.epoch")
seconds_to_observed_zero=$((drain_end_epoch - load_end_epoch))
if (( seconds_to_observed_zero < 0 || seconds_to_observed_zero > 1800 )); then
  echo 'STOP: discovery drain deadline failed' >&2
  exit 1
fi
bash scripts/capture-evidence.sh "$LAST_RUN" drained discovery 100 30s
```

**Expect:** Wrapper zero; no drops; HTTP passes; run rows equal `accepted_total`; quarantine after-minus-before is zero.

**If different:** Any threshold, reconciliation, quarantine, host-safety, or 30-minute-drain failure makes 100 fail.

**Recover or stop:** Preserve evidence. Try 50, 25, and so on; if 1 fails, return to correctness. Never purge undrained accepted work.

**Evidence:** Summary, one benchmark manifest, matching manifest hashes and integrity status across before/after/drained evidence, drain markers, vmstat, scoped Docker stats, queue trace, and native logs. `after` is captured seconds after k6 while a live worker may already be draining, so do not pretend it is an exact end timestamp.

## Guided action 6.3 — Expand then narrow

**Before each candidate:** Prior work drained/reconciled; health passes at new rate; same code, versions, thresholds, durations, VUs, and host state.

**Do:** Double a pass until first failure: 100, 200, 400, and so on. Then test midpoints until the gap is at most 10% of the lower bound.

**Expect:** A bracket such as last pass 800, first fail 900, with a named failed rule.

**If different:** Non-monotonicity suggests noise, thermals, state growth, or competing limits.

**Recover or stop:** Cool down, reconcile, reset, and repeat both rates. Persisting non-monotonicity becomes reported uncertainty.

**Evidence:** One row per candidate, including failures.

## Guided action 6.4 — Reset between measured series

**Before:** Archive evidence; account for all accepts; stop API/worker with `Ctrl-C`; prove no native client traffic; dependencies remain healthy; only synthetic data is scoped.

**Do:** Repeat action 6.1, including its stop, reset, independent verification, and fresh-start sequence.

**Expect:** The new series begins from independently verified zero stream/table/quarantine state.

**If different:** State is not comparable and the next run must not start.

**Recover or stop:** Use action 6.1's partial-reset recovery.

**Evidence:** A new reset/zero/start bundle linked to the next series.

## Overload safe stop

If swap grows, free disk becomes unsafe, OOM/restart/thermal evidence appears, or the stream rejects publishes: stop k6 first, then stop the API so it cannot accept more. If storage is healthy, keep the worker running to drain already accepted work. Preserve evidence and reconcile before cleanup. A run with OOM, container restart, low disk, or throttling is failed/inconclusive, never a headline pass.

## Less-guided check

For one pass and one failure, identify generator, API, NATS sync, worker/DB, or host/storage as the likely boundary using two observations.

**Completion evidence:** Last-pass/first-fail burst bracket and preliminary sustainable bracket.

**Optional depth:** Approximate scheduled confirmation events as `low_rate × 120 + average(low_rate,target) × 180 + target × 600`; actual `accepted_total` is reconciliation truth.

# Module 7 — Confirm capacity and measure drain

## Outcome

You will run fixed confirmations, demand repeatability, reconcile state, and separately time controlled drain.

## Mental model

Discovery finds a neighborhood; repeat confirmation turns it into a conservative observed bound. Burst, sustainable, and drain rates can differ because they measure queue acceptance, concurrent end-to-end balance, and post-load processing under different contention.

**Worked example:** Three burst trials at 1,000 accepted RPS can pass while backlog grows, whereas three sustainable trials may pass only at 700. A post-load drain could then measure 900 rows/s because k6 and new API events are no longer competing with the worker.

## Guided action 7.1 — Confirm burst three times

**Before:** Bracket and same-rate health pass; `.env` is 2-minute low/3-minute ramp/10-minute hold; disk safe; host quiet. Immediately before every trial—including trial one—complete action 6.4 so the trial has its own archived reset, independently verified zeros, and fresh API/worker start bundle.

**Do per trial:**

```bash
CANDIDATE_RPS=1000
bash scripts/run-benchmark.sh confirmation "$CANDIDATE_RPS"
```

Set the variable to the discovered candidate. Poll until zero or 30 minutes, capture `drained` using the printed run ID, and reconcile `accepted_total`. Complete action 6.4 again immediately before the next trial; never let one confirmation's state become another's starting state.

Use the printed run ID for an automated, timestamped drain gate:

```bash
TRIAL_RUN=replace-with-the-printed-run-id
bash scripts/wait-for-drain.sh "$TRIAL_RUN" 1800
bash scripts/capture-evidence.sh "$TRIAL_RUN" drained confirmation \
  "$CANDIDATE_RPS" "${DISCOVERY_DURATION:-30s}"
RUN_ID="$TRIAL_RUN" BURSTLAB_MODE=count ./burstlab
load_end_epoch=$(date -u -d "$(<"results/${TRIAL_RUN}-load-end.utc")" +%s)
drain_end_epoch=$(<"results/${TRIAL_RUN}-drain-end.epoch")
seconds_to_observed_zero=$((drain_end_epoch - load_end_epoch))
printf 'seconds_from_k6_exit_to_observed_zero=%s\n' "$seconds_to_observed_zero"
if (( seconds_to_observed_zero < 0 || seconds_to_observed_zero > 1800 )); then
  echo 'STOP: burst drain deadline failed' >&2
  exit 1
fi
bash scripts/summarize-queue-trace.sh \
  "results/${TRIAL_RUN}-queue-trace.txt" \
  "results/${TRIAL_RUN}-load-start.utc" 300 600 \
  | tee "results/${TRIAL_RUN}-queue-summary.txt"
```

**Expect:** All three trials pass every burst rule. The summary prints attempted and accepted hold RPS separately.

**If different:** One failed trial means the rate is not confirmed under this conservative contract.

**Recover or stop:** Preserve failure, lower candidate, rerun health, and start three fresh trials.

**Evidence:** Three complete bundles, each with overall and hold worker-connection min/max all one, one unchanged manifest SHA, and integrity `match`. Report each plus medians, but capacity is the highest target for which all three pass.

## Guided action 7.2 — Confirm sustainable RPS

If the burst trials satisfy sustainable rules, reuse them. Otherwise bracket lower and run three confirmations.

**Before:** Candidate passes health/burst. Immediately before every newly executed sustainable trial—including its first—complete action 6.4 and prove exactly one worker is connected. If the already completed burst trials satisfy every sustainable rule and are reused, do not rerun or relabel their starting state.

**Do:**

```bash
SUSTAINABLE_RPS=700
bash scripts/run-benchmark.sh confirmation "$SUSTAINABLE_RPS"
```

Set the actual candidate and repeat three times. For every newly executed sustainable trial, copy the printed run ID and immediately run the 60-second drain gate, capture drained evidence, and compute the conservative detection delay from k6 exit:

```bash
TRACE_RUN=replace-with-the-printed-run-id
bash scripts/wait-for-drain.sh "$TRACE_RUN" 60
bash scripts/capture-evidence.sh "$TRACE_RUN" drained confirmation \
  "$SUSTAINABLE_RPS" "${DISCOVERY_DURATION:-30s}"
load_end_epoch=$(date -u -d "$(<"results/${TRACE_RUN}-load-end.utc")" +%s)
drain_end_epoch=$(<"results/${TRACE_RUN}-drain-end.epoch")
seconds_to_observed_zero=$((drain_end_epoch - load_end_epoch))
printf 'seconds_from_k6_exit_to_observed_zero=%s\n' "$seconds_to_observed_zero"
if (( seconds_to_observed_zero < 0 || seconds_to_observed_zero > 60 )); then
  echo 'STOP: sustainable drain deadline failed' >&2
  exit 1
fi
```

Require the printed difference to be between 0 and 60 seconds. It includes the wrapper's after-capture and command-launch delay, so it is a conservative 60-second test. If burst trials are reused, keep each original `drain-end.epoch` created in action 7.1—do not rerun the waiter after the queue is already zero—and calculate the same difference from that original marker. Only a reused trial whose original difference is at most 60 seconds can satisfy the sustainable rule. Then record hold `B_start`, `B_end`, `B_max`, slope, and worker-connection range.

For each printed run ID, extract the exact default hold window. The load-start marker is written immediately before k6; low plus ramp is 300 seconds and hold is 600 seconds:

```bash
TRACE_RUN=replace-with-the-printed-run-id
bash scripts/summarize-queue-trace.sh \
  "results/${TRACE_RUN}-queue-trace.txt" \
  "results/${TRACE_RUN}-load-start.utc" 300 600 \
  | tee "results/${TRACE_RUN}-queue-summary.txt"
```

The tabular rows identify every sample and `in_hold=1`; the footer calculates hold samples, `B_start`, `B_end`, `B_max`, delta, slope, and worker-connection minima/maxima. The marker is k6 process-invocation time, not an exact internal scenario-start signal; startup offset is normally small but not guaranteed. The summarizer rejects insufficient sample/boundary coverage, and the result remains an approximately one-second trace. If durations change, convert low-plus-ramp and hold to seconds and pass those values instead.

**Expect:** All three have `B_end <= B_start + 1000`, slope at or below the printed one-batch tolerance, overall and hold worker-connection min/max all one, one unchanged manifest SHA with integrity `match`, zero within 60 seconds, exact reconciliation, and zero quarantine delta.

**If different:** Burst acceptance exceeds sustainable processing—a valid result.

**Recover or stop:** Lower target, revalidate health, repeat. If host state changed, rerun the prior pass.

**Evidence:** Three passing bundles at the sustainable rate.

After each trial reconciles, perform action 6.4 before starting the next trial.

## Guided action 7.3 — Create controlled drain backlog

This measures the worker/PostgreSQL pipeline after offered load stops. It is not sustainable-rate evidence.

**Before:** Clean state; API/worker initially running; durable consumer exists; queue empty; seed rate passed burst discovery. Stop worker with `Ctrl-C`, leave API running.

**Do:**

```bash
export DRAIN_RUN="drain$(date -u +%Y%m%dT%H%M%SZ)"
BURST_RPS=1000
DRAIN_DURATION=30s
RUN_ID="$DRAIN_RUN" ALLOW_STOPPED_WORKER=1 \
  bash scripts/run-benchmark.sh discovery "$BURST_RPS" "$DRAIN_DURATION"
RUN_ID="$DRAIN_RUN" BURSTLAB_MODE=count ./burstlab
nats --server "$NATS_URL" consumer info EVENTS burstlab-worker
```

Set `BURST_RPS` to a passing seed. The wrapper warns because worker absence is intentional.

If the resulting backlog would drain in less than ten seconds, reset and repeat this action with a longer bounded discovery preload:

```bash
export DRAIN_RUN="drain$(date -u +%Y%m%dT%H%M%SZ)"
DRAIN_DURATION=2m
RUN_ID="$DRAIN_RUN" ALLOW_STOPPED_WORKER=1 \
  bash scripts/run-benchmark.sh discovery "$BURST_RPS" "$DRAIN_DURATION"
```

The third argument changes only this discovery duration and is captured in evidence. Before using 2 minutes—or at most 5 minutes if 2 is still too short—verify `BURST_RPS × duration_seconds × 2048` stays below 4 GiB and that at least that much real disk headroom exists. Two KiB per small course event plus a 4-GiB ceiling leaves deliberate overhead margin below the stream's 8-GiB cap. Use a new `DRAIN_RUN` after every reset.

**Expect:** Event HTTP rules pass, run DB count zero, pending approximately accepted total.

**If different:** Nonzero rows mean worker/prior ID ambiguity. HTTP failure means an unclean seed.

**Recover or stop:** Preserve and exclude the probe, drain/reconcile, reset, choose unique ID, repeat lower.

**Evidence:** Summary, after snapshot, zero pre-restart rows, starting pending.

## Guided action 7.4 — Time drain

**Before:** Backlog exists; k6 stopped; API idle. Use enough synthetic backlog that the expected drain lasts at least ten seconds; otherwise the one-second observation/timing resolution is too coarse for an exact rate.

**Do:** First run the automated waiter in the control terminal. It sees the existing nonzero backlog and remains active:

```bash
bash scripts/wait-for-drain.sh "$DRAIN_RUN" 1800
```

While it is polling, copy the exact `DRAIN_RUN` value into terminal W. Load `.env`, record start immediately before launching the worker, and keep its log:

```bash
export DRAIN_RUN=replace-with-the-exact-drain-run-id
set -a; source .env; set +a
date -u +%FT%TZ
date +%s | tee "results/${DRAIN_RUN}-drain-start.epoch"
BURSTLAB_MODE=worker ./burstlab 2>&1 | tee "results/${DRAIN_RUN}-drain-worker.log"
```

When the worker reaches zero backlog, the control-terminal waiter writes `drain-end.epoch` and exits. Then capture evidence in the control terminal:

```bash
RUN_ID="$DRAIN_RUN" BURSTLAB_MODE=count ./burstlab
bash scripts/capture-evidence.sh "$DRAIN_RUN" drained discovery "$BURST_RPS" "$DRAIN_DURATION"
```

Calculate:

```text
drain_seconds = end_epoch - start_epoch
pipeline_drain_rate = final run-specific rows / drain_seconds
```

This includes worker startup and approximately one polling interval plus NATS CLI query time; disclose both. Because the waiter starts before the worker timestamp, operator terminal-switch delay is excluded. For higher precision, create a larger bounded backlog.

**Expect:** Run rows equal `accepted_total`; quarantine delta zero; backlog zero; positive seconds.

**If different:** Mismatch, quarantine, backlog, worker error, or coarse zero-second timing invalidates the exact rate. If backlog drains too quickly to time, report only `>= sustainable accepted RPS` or create a larger bounded preload; never invent precision.

**Recover or stop:** Keep invalid probe, repair, repeat cleanly. Use committed rows, not scheduled requests.

**Evidence:** Start/end UTC+epoch, initial/final backlog, final rows, formula, drained snapshot.

## Less-guided check

Explain why post-load drain can exceed sustainable ingress and why burst can exceed both; include idle generator/API and finite queue.

**Completion evidence:** Three burst trials, three sustainable trials (possibly same set), one valid drain result or explicit lower bound.

**Optional depth:** Repeat with larger backlog and investigate checkpoint/cache/index effects. [PostgreSQL statistics docs](https://www.postgresql.org/docs/18/monitoring-stats.html) explain why fresh queries/trends beat one snapshot.

# Module 8 — Interpret, report, and bridge to AWS

## Outcome

You will state three bounded rates, explain failure, and map causal roles without performance equivalence.

## Mental model

A benchmark report is a proof boundary, not a trophy. It must make it easier for another person to reproduce the observation and harder to accidentally generalize it beyond the tested shape.

**Worked example:** “Burst 1,000; sustainable 700; drain 900 rows/s” is internally coherent when queue acceptance outruns concurrent DB processing but the worker drains faster once k6 and new API work stop.

## Guided action 8.1 — Build the bounded report

**Before:** All required trials, drain evidence, host identity, logs, and failed-run evidence are preserved.

**Do:** Fill the following table once for the frozen environment and once per run where appropriate. Use `n/a`, not zero, when unmeasured. Evidence collection itself samples and writes on the tested host; disclose that overhead.

| Field | Value |
|---|---|
| Commit / non-secret source fingerprints | |
| Benchmark manifest path / SHA-256 | |
| Before/after/drained `configuration_integrity` | |
| Host, CPU topology, RAM, kernel/Ubuntu | |
| Disk model, Docker-root device/filesystem, free space | |
| Docker/Compose versions and resource limits | |
| Go/k6/NATS CLI versions | |
| Image tags and target-resolved digests | |
| nats.go / pgx versions | |
| NATS file/R=1/8 GiB/DiscardNew/sync-always | |
| Profile, target, durations, VUs, thresholds | |
| Run ID / trial | |
| Hold scheduled / attempts / accepts | |
| Attempted hold RPS / accepted hold RPS | |
| Hold `202` check rate / failure / p95 / dropped | |
| `B_start` / `B_end` / `B_max` | |
| Hold backlog slope / one-batch slope tolerance | |
| Overall and hold worker connections min / max | |
| Run rows / quarantine before-after delta | |
| Seconds to zero / pipeline drain RPS | |
| CPU, RAM, swap, I/O, restarts, thermals | |
| Pass/fail/inconclusive and reason | |

State:

> On the recorded Ubuntu host and exact lab configuration, the highest scheduled burst target whose three ten-minute holds all met the burst rules was **___ RPS**; accepted hold RPS values were **[___, ___, ___]**, with median **___ RPS**. The highest scheduled sustainable target whose three holds all also met the non-growing-backlog and 60-second-drain rules was **___ RPS**; accepted hold RPS values were **[___, ___, ___]**, with median **___ RPS**. A separate stopped-worker backlog of **___ committed events** drained in **___ seconds**, or **___ rows/s** through the NATS-worker-PostgreSQL pipeline. These are local, co-located, finite-duration observations; they do not predict SQS, RDS, a networked generator, or production availability.

Also report the first failed rate/rule, all trials, paired health results, evidence-backed bottleneck diagnosis, and every deviation.

**Expect:** Every number can be traced to one run ID and formula; the three rates are named separately; the first failure and all deviations remain visible.

**If different:** A missing summary, differing manifest hash, integrity mismatch, unexplained count, hidden failure, unrecorded configuration, or rate without three passing trials makes the claim incomplete.

**Recover or stop:** Relabel it `inconclusive`, preserve what exists, and run only the smallest missing experiment. Do not infer a metric that was not captured.

**Evidence:** The completed table, raw run bundles, formulas, source fingerprints, and limitation statement.

## Local-to-AWS role map

| Local relationship | AWS analogue | Non-equivalence |
|---|---|---|
| native co-located k6 | separate EC2 generators | local generator competes for host resources |
| loopback Go API | API instances behind internal ALB | no network/LB/multi-instance/TLS cost locally |
| JetStream `PubAck` | acknowledged SQS send | different batching, durability, quotas, latency, billing |
| one file work queue | SQS Standard | one disk/replica is not a managed regional queue |
| pull consumer + ack | SQS receive/visibility/delete | mechanisms and tuning differ |
| local PostgreSQL | private RDS PostgreSQL | no network/TLS/managed storage/control plane |
| local credentials | IAM and Secrets Manager | course credentials are not production identity |
| local traces | CloudWatch/service metrics | names, windows, and cost differ |

What transfers is causality: durable acceptance before `202`; idempotent commit before removing work; separate acceptance, backlog, and completion. RPS does not transfer.

## Integrated performance task

Submit evidence and an explanation that:

1. Operates a clean whole and passes correctness.
2. Shows a discovery bracket including an informative failure.
3. Gives three burst and three sustainable confirmations unless one set satisfies both.
4. Reconciles `accepted_total` to run-specific rows after every confirmation.
5. Computes controlled drain from committed rows/time or states a justified lower bound.
6. Traces normal and stopped-worker paths through all five states.
7. Explains the first failure with two independent observations.
8. Names three AWS black boxes.
9. States all three rates with limitations.
10. Performs safe cleanup and proves named evidence/volumes were retained.

**Pass evidence:** Artifacts reproduce calculations; failed/dropped runs remain visible; every rate satisfies its definition; explanation preserves invariants and non-equivalence.

**Repair evidence:** Relabel irreproducible capacity as inconclusive, identify the failed rule, and confirm a smaller bound.

## Less-guided check

Give your report to a reader who has not seen the lab. Ask them to identify the machine, reproduce the candidate profile, calculate accepted RPS and drain RPS, name the first failure, and explain why AWS performance remains unknown. Repair any answer they cannot find directly.

## Troubleshooting by symptom

### Port already used

Use `ss -ltnp`, identify owner, and stop only a known course process. Do not change to public binds or kill unexplained work.

### Unhealthy Compose service

Use `docker compose logs --tail=100 nats postgres`. Preserve volumes until proving they contain only disposable synthetic data.

### API 401 or 400

For `401`, reload local `TOKEN` and ensure API started with matching hash. For `400`, check one strict JSON object, 1-KiB body, ID rules, timestamp, and 256-byte value. Rejected work must not enter NATS.

### API 503

Check transport readiness, NATS health/logs, stream capacity, disk, and publish timeout. Full `DiscardNew` correctly causes `503`; changing limits creates a new benchmark.

### Worker absent

The durable consumer and connected client `burstlab-worker` must exist. Start terminal W and resolve its first error. `ALLOW_STOPPED_WORKER=1` is only for the explicit drain probe.

### Dropped iterations

Compare same-rate health. If health drops, adjust VUs up front or lower rate. If health passes but events drop, inspect API/NATS latency and host pressure. Preserve the old run.

### High p95 without drops

The generator scheduled work but a path slowed. Compare health, API errors, NATS/storage, queue trend, and DB counters. One CPU snapshot is not a diagnosis.

### Growing backlog

You likely crossed sustainable rate but may remain below burst. Stop new load, drain at most 30 minutes, reconcile, and lower sustainable candidate.

### Ack-pending/redelivery

Inspect DB errors, transaction time, `AckWait`, connection errors, and restarts. Keep idempotency; never ack earlier to make metrics look better.

### Disk/stream saturation

Use the overload safe stop. `DiscardNew` rejects new work rather than evicting accepted old work. Drain and reconcile before reset.

### Counts mismatch

Compare exact run `accepted_total`, run rows, quarantine delta, pending, and ack-pending. Mark failed after deadline; never substitute total table rows.

### Missing summary

Diagnose k6 log/exit. Do not reconstruct a headline from console fragments.

## Guided action 8.2 — Safe stop and cleanup

**Before:** All accepted work is reconciled or explicitly recorded as unresolved, and result files are archived.

**Do:**

Press `Ctrl-C` in API and worker terminals, then:

```bash
docker compose down
```

**Expect:** Containers stop; named volumes/results remain.

**If different:** A hanging process/container can leave writes in progress or state uncertain.

**Recover or stop:** Inspect native processes, `docker compose ps`, and logs. Do not delete volumes. For a clean synthetic rerun use action 6.1; deletion is unrecoverable, so archive first.

**Evidence:** No course listeners/processes remain, Compose services are stopped, and named volumes/results still exist.

**Completion evidence:** A reproducible bounded report plus the integrated explanation and cleanup evidence, with all required raw evidence linked or archived.

**Optional depth:** Repeat one passing confirmation on another day without changing configuration. Treat any difference as a stability study, not as permission to average away the original trials.

## Glossary

| Term | Meaning here |
|---|---|
| Accepted | API received configured stream acknowledgement and returned `202` |
| Acknowledged | Worker told consumer a committed/quarantined message may be removed |
| At-least-once | Failure can repeat processing; side effects need idempotency |
| Backlog | `num_pending + num_ack_pending` |
| Burst acceptance | HTTP/queue passes while downstream backlog may grow temporarily |
| Drain rate | Run-specific committed rows / controlled post-load drain seconds |
| Durable consumer | Named progress surviving worker restart |
| Idempotency | Repeating an ID has one database effect |
| Open model | Arrivals scheduled independently of completion |
| PubAck | Stream accepted/stored publication under configured policy |
| Sustainable | Acceptance and completion keep pace under defined rules |

## Evidence and limitations

### Authoring execution evidence

Before release, the lab was checked on a smaller WSL2 Ubuntu environment with 8 logical CPUs and about 7.6 GiB RAM, Go 1.25.10, Docker 28.3.3/Compose 2.39.1, k6 2.2.0, NATS CLI 0.4.0, NATS Server 2.14.5, and PostgreSQL 18.6. Current-source Go unit and race tests plus vet passed; so did shell syntax, Compose resolution, the controlled k6 inspection, healthy dependency/native startup, strict NUL rejection, direct malformed-message quarantine, consumer/stream contract validation, reconciliation, and guarded reset. Earlier development exercises also observed authentication rejection, queue-unavailable `503`, duplicate suppression, stopped-worker recovery, and smoke load.

The final current-source functional bundle `releasefinal2` used a deliberately shortened 2-second low, 2-second ramp, and 6-second hold at a 20-RPS target. It accepted 142 total events and committed 142 run rows, including 120/120 hold `202`s; hold p95 was about 19.1 ms, drops and quarantine were zero, overall/hold worker minima and maxima were all one, sampled backlog was 0→1 with maximum 1, and observed zero was recorded 38 seconds after k6 exit. Before/after/drained evidence used the same manifest SHA-256 and reported configuration integrity `match`. This checks mechanics and evidence plumbing only; it is deliberately not a capacity result.

The target is separate. Until the learner runs there, unverified items include its CPU topology, visible memory, Docker-root storage, Docker allocation, native versions, resolved digests, thermals/ambient state, and all rates.

### Known scaffold limits

- One NATS replica and one PostgreSQL instance are single points of failure.
- `sync_interval: always` strengthens the local PubAck/power-loss boundary but cannot survive disk/node loss and affects throughput.
- Monitoring and DB are loopback plaintext; no TLS/service identity.
- One synthetic tenant/small payload does not model production cardinality/schema.
- One worker/fixed batching; no horizontal scaling or dead-letter policy.
- Ten-minute hold is a bounded sample, not soak.
- Co-located k6 measures whole-machine, not isolated server capacity.
- Monitoring runs on and writes to the tested host, perturbing it.
- API `/stats` is API-process-local; its worker fields remain zero. Use worker logs, PostgreSQL, and consumer evidence for commit/ack state.
- PostgreSQL cumulative counters and sampled system metrics aid diagnosis but are not per-request traces.

## Authoritative references

Checked 23 August 2026:

- [Go release history](https://go.dev/doc/devel/release)
- [NATS Server 2.14.5](https://github.com/nats-io/nats-server/releases/tag/v2.14.5)
- [NATS Docker Official Image](https://github.com/docker-library/official-images/blob/master/library/nats)
- [nats.go 1.53.1](https://github.com/nats-io/nats.go/releases/tag/v1.53.1)
- [NATS CLI 0.4.0](https://github.com/nats-io/natscli/releases/tag/v0.4.0)
- [JetStream concepts/durability](https://github.com/nats-io/nats.docs/blob/master/nats-concepts/jetstream/README.md)
- [JetStream publishing](https://docs.nats.io/learn/jetstream/publishing)
- [JetStream delivery/ack](https://docs.nats.io/learn/jetstream/delivery-and-acknowledgment)
- [NATS monitoring](https://docs.nats.io/learn/monitoring/monitoring-endpoints)
- [PostgreSQL 18.6](https://www.postgresql.org/docs/current/release-18-6.html)
- [PostgreSQL Official Image](https://github.com/docker-library/official-images/blob/master/library/postgres)
- [PostgreSQL statistics](https://www.postgresql.org/docs/18/monitoring-stats.html)
- [pgx changelog](https://raw.githubusercontent.com/jackc/pgx/master/CHANGELOG.md)
- [k6 2.2.0](https://github.com/grafana/k6/releases/tag/v2.2.0)
- [k6 open/closed models](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/open-vs-closed/)
- [k6 VU allocation](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/arrival-rate-vu-allocation/)
- [k6 dropped iterations](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/dropped-iterations/)
- [k6 thresholds](https://grafana.com/docs/k6/latest/using-k6/thresholds/)
- [k6 summaries](https://grafana.com/docs/k6/latest/results-output/end-of-test/custom-summary/)
- [Docker host networking](https://docs.docker.com/engine/network/drivers/host/)

## Final rule

Do not report “this machine handles X RPS” unless `X` names burst or sustainable, all three confirmations pass, k6 scheduled the work, accepted events reconcile, and exact conditions travel with the number. Report drain separately. Never use the local result as an AWS prediction.
