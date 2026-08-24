# Load testing BurstLab on one machine: 1→N API and worker processes

Exact commands, in order. Everything runs on the single lab box until the last
section. Run every command from `labs/burstlab-single-machine`.

There is no scaling *tool* for the processes — the binary already scales by
running more copies of itself (`BURSTLAB_MODE=worker` shares one durable
JetStream consumer; `BURSTLAB_MODE=api` is stateless). The only thing you
actually need to add is **HAProxy**, because k6 sends every request to one URL
and you need something to fan it across several API ports.

---

## 0. Once per machine

```bash
cd ~/csprojects/burstlab/labs/burstlab-single-machine
bash scripts/install-prereqs.sh          # go, k6, nats CLI
bash scripts/preflight.sh                # records host, flags target mismatches
go build -o burstlab .
[[ -f .env ]] || cp .env.example .env
mkdir -p results/scale
```

Every terminal below starts with the lab env loaded:

```bash
cd ~/csprojects/burstlab/labs/burstlab-single-machine
set -a; source .env; set +a
```

---

## 1. Baseline: 1 API, 1 worker

Start the dependencies:

```bash
docker compose up -d --wait
docker compose ps
```

Terminal A — worker:

```bash
BURSTLAB_MODE=worker ./burstlab
```

Terminal B — API:

```bash
BURSTLAB_MODE=api ./burstlab
```

Terminal C — prove the path end to end, then measure:

```bash
bash scripts/run-benchmark.sh smoke                 # 1 request, must pass
bash scripts/run-benchmark.sh health 500            # HTTP only, no queue
bash scripts/run-benchmark.sh discovery 500 60s     # real events, 60s
```

`discovery` is the sweep tool. Raise the rate until a run fails, then step back:

```bash
for rps in 500 1000 1500 2000 2500 3000; do
  bash scripts/run-benchmark.sh discovery "$rps" 60s || break
done
```

A run **fails** on any of: `http_req_failed` above 0.5%, p95 above 150 ms, or
`dropped_iterations > 0`. The highest rate that passes is your 1+1 knee. Write
it down — every later number is compared against it.

Between runs, check the queue actually drained rather than hiding a backlog:

```bash
nats consumer info EVENTS burstlab-worker        # num_pending should return to 0
BURSTLAB_MODE=count ./burstlab                   # committed row counts
```

After a run that left a backlog:

```bash
bash scripts/wait-for-drain.sh "$RUN_ID"
bash scripts/capture-evidence.sh "$RUN_ID" drained discovery "$RPS" 60s
```

Reset between experiments (stop API and worker first — it purges everything):

```bash
bash scripts/reset-lab.sh --yes
```

---

## 2. Which side is the bottleneck?

Before scaling anything, find out which half is saturated. One command each:

```bash
curl -s 127.0.0.1:8080/stats; echo        # accepted / rejected / errors
nats consumer info EVENTS burstlab-worker # num_pending, num_ack_pending
```

- `num_pending` climbing during the run → **worker-bound** (§3). The API accepts
  fine, the drain side can't keep up.
- API p95 rising with `num_pending` flat at ~0 → **API-bound** (§4).
- Both flat but `dropped_iterations > 0` → **k6 is the bottleneck**, not the
  system. See §6.

Watch it live during a run, in its own terminal:

```bash
watch -n1 'nats consumer info EVENTS burstlab-worker | grep -E "Pending|Waiting|Redeliver"'
```

---

## 3. Scale workers horizontally

Multiple worker processes bind the same durable pull consumer
(`burstlab-worker`) and split the stream between them. No coordination, no
config, no tool.

**Cap the DB pool first.** Each worker opens a pgx pool sized to your CPU count
by default (8 here), and Postgres allows ~97 client connections. Four workers is
already 32 connections; eight is 64. Pin it explicitly:

```bash
export DATABASE_URL="postgres://burstlab:burstlab@127.0.0.1:5432/burstlab?sslmode=disable&pool_max_conns=4"
```

Start N workers, keeping the PIDs so you can stop exactly these:

```bash
WORKERS=4
: > results/scale/worker.pids
for i in $(seq 1 "$WORKERS"); do
  BURSTLAB_MODE=worker ./burstlab >"results/scale/worker-$i.log" 2>&1 &
  echo $! >> results/scale/worker.pids
done
```

Confirm they all attached to the one consumer:

```bash
curl -s http://127.0.0.1:8222/connz | grep -c '"burstlab-worker"'   # should equal $WORKERS
nats consumer info EVENTS burstlab-worker | grep Waiting            # pull requests from all of them
```

Stop them:

```bash
xargs -r kill < results/scale/worker.pids && : > results/scale/worker.pids
```

Now re-sweep. `scripts/run-benchmark.sh` refuses to run event load unless
exactly one worker is connected, so scaled runs call k6 directly:

```bash
RUN_ID="scale-w${WORKERS}-a1-$(date -u +%H%M%S)" \
PROFILE=discovery TARGET_RPS=3000 DISCOVERY_DURATION=60s \
URL=http://127.0.0.1:8080 TOKEN="$TOKEN" \
PRE_ALLOCATED_VUS=400 MAX_VUS=4000 \
k6 --config k6-config.json run load.js
```

Sweep the same ladder as §1 (1, 2, 4, 8 workers × rising RPS) and record where
each stops improving.

**Optional — keep the full evidence capture on scaled runs.** One-line
relaxation of the singleton gate, which also changes
`LAB_SOURCE_FINGERPRINT` in the manifest so the modification is visible in the
evidence:

```bash
sed -i 's/if \[\[ $worker_connections != 1 \]\]; then/if (( worker_connections < 1 )); then/' scripts/run-benchmark.sh
git diff --stat scripts/run-benchmark.sh
```

Then `bash scripts/run-benchmark.sh discovery 3000 60s` works with N workers and
still writes vmstat, docker stats, the queue trace, and before/after evidence.
Revert with `git checkout scripts/run-benchmark.sh` before publishing baseline
numbers.

---

## 4. Scale the API horizontally (HAProxy in front)

The API is stateless, so instances only need distinct ports. k6 needs one
address, so HAProxy round-robins 8080 across them.

Start N API instances on 8081+:

```bash
APIS=2
: > results/scale/api.pids
for port in $(seq 8081 $((8080 + APIS))); do
  HTTP_ADDR="127.0.0.1:$port" BURSTLAB_MODE=api ./burstlab >"results/scale/api-$port.log" 2>&1 &
  echo $! >> results/scale/api.pids
done
for port in $(seq 8081 $((8080 + APIS))); do curl -fsS "127.0.0.1:$port/health/ready" && echo " $port ready"; done
```

Generate the HAProxy config for exactly those ports:

```bash
{
  echo 'global'
  echo '  maxconn 20000'
  echo 'defaults'
  echo '  mode http'
  echo '  timeout connect 2s'
  echo '  timeout client 15s'
  echo '  timeout server 15s'
  echo 'frontend ingest'
  echo '  bind 127.0.0.1:8080'
  echo '  default_backend api'
  echo 'backend api'
  echo '  balance roundrobin'
  echo '  option httpchk GET /health/ready'
  for port in $(seq 8081 $((8080 + APIS))); do
    echo "  server api$port 127.0.0.1:$port check inter 2s"
  done
  echo 'frontend lbstats'
  echo '  bind 127.0.0.1:8404'
  echo '  stats enable'
  echo '  stats uri /'
} > results/scale/haproxy.cfg
```

Run it with host networking, outside Compose so the benchmark's Compose
fingerprint stays comparable to your 1+1 baseline:

```bash
docker run -d --name burstlab-lb --network host \
  -v "$PWD/results/scale/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
  haproxy:3.2.22-alpine3.24

docker image inspect --format '{{index .RepoDigests 0}}' haproxy:3.2.22-alpine3.24 \
  | tee results/scale/lb-image-digest.txt
curl -fsS 127.0.0.1:8080/health/ready && echo " lb ready"
```

Check the config before starting, so a typo fails in one second instead of
looking like a load failure:

```bash
docker run --rm -v "$PWD/results/scale/haproxy.cfg:/tmp/haproxy.cfg:ro" \
  haproxy:3.2.22-alpine3.24 haproxy -c -f /tmp/haproxy.cfg
```

**Verify the fan-out from the LB itself.** This is why HAProxy and not nginx:
per-backend request counts are built in, so you prove even distribution without
trusting the app counters:

```bash
curl -s 127.0.0.1:8404/\;csv | cut -d, -f1,2,5,8,18
```

Columns are `pxname,svname,scur,stot,status` — every `api<port>` row should show
a similar `stot` (total sessions) and `status=UP`. Cross-check against the app's
own counters if you want both sides:

```bash
for port in $(seq 8081 $((8080 + APIS))); do printf '%s ' "$port"; curl -s "127.0.0.1:$port/stats"; echo; done
```

During a run, watch the LB's view of queueing and errors:

```bash
watch -n1 'curl -s 127.0.0.1:8404/\;csv | cut -d, -f1,2,3,5,8,13,14,18'
```

That is `pxname,svname,qcur,scur,stot,ereq,econ,status`. Line 1 of the CSV is a
`#`-prefixed header naming every column, so
`curl -s 127.0.0.1:8404/\;csv | head -1 | tr , '\n' | nl` re-derives any index
you want. Non-zero `qcur`/`ereq`/`econ` at the LB means requests died before the
API saw them — a different failure from an API that answered slowly.

`URL=http://127.0.0.1:8080` is unchanged, so §3's k6 command and
`scripts/run-benchmark.sh` both keep working — they now measure the whole fleet.

Teardown:

```bash
docker rm -f burstlab-lb
xargs -r kill < results/scale/api.pids && : > results/scale/api.pids
```

---

## 5. The scaling matrix

Run each cell as a 60s discovery at the rate you're testing, one variable at a
time, resetting between cells:

| APIs | Workers | Command shape |
|---|---|---|
| 1 | 1 | `bash scripts/run-benchmark.sh discovery $RPS 60s` |
| 1 | 2, 4, 8 | §3 loop, then the raw-k6 command |
| 2, 4 | 1 | §4 loop + HAProxy, then `run-benchmark.sh` |
| 2, 4 | 4, 8 | both loops + HAProxy, raw k6 |

Then confirm the winning shape holds under a long ramp instead of a 60s burst:

```bash
PROFILE=confirmation TARGET_RPS=<winner> LOW_DURATION=2m RAMP_DURATION=3m HOLD_DURATION=10m \
RUN_ID="confirm-$(date -u +%H%M%S)" URL=http://127.0.0.1:8080 TOKEN="$TOKEN" \
k6 --config k6-config.json run load.js
```

---

## 6. Ceilings you will hit on one box

These are hard-coded or environmental. When a scaling step stops helping, it is
almost always one of these, not "the machine is full":

| Ceiling | Where | Effect |
|---|---|---|
| `maxAckPending = 20000` | `main.go:37` | Total unacked messages across **all** workers. Past ~20 workers × 1000-message fetches, extra workers just wait. |
| `batchSize = 1000`, `batchWindow = 50ms` | `main.go:32-33` | Each worker fetches up to 1000 per 50 ms window; that is the per-worker throughput unit. |
| pgx pool = `NumCPU` per worker | `pgxpool` default | N workers × 8 connections vs Postgres ~97. Pin `pool_max_conns` (§3) or connections fail. |
| One NATS server, one Postgres | `compose.yaml` | Neither scales horizontally here. When the queue or the DB is the limit, more app processes change nothing. |
| k6 shares the CPUs | same box | `dropped_iterations > 0` means the *generator* fell behind. Move k6 to a second machine before believing that number. |
| Total CPUs | this box: 8 | k6 + N APIs + N workers + nats + postgres all compete. Watch `results/${RUN_ID}-vmstat.txt`. |

---

## 7. When to stop and go multi-machine

Move off one box when either is true:

1. `dropped_iterations > 0` at a rate the system handles fine — the load
   generator is the limit. Move k6 to its own machine first; it is the cheapest
   split and it needs no code change, only `URL=http://<lab-ip>:8080` and
   `HTTP_ADDR=0.0.0.0:8080`.
2. Adding both an API and a worker no longer raises the passing rate, and vmstat
   shows the CPUs saturated. Then split NATS and Postgres onto their own hosts.

Everything above stays valid across that move: the process-per-instance model,
HAProxy as the fan-out, and the same discovery/confirmation profiles.
