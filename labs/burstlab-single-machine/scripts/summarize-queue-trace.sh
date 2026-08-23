#!/usr/bin/env bash
set -euo pipefail

trace=${1:-}
load_start_file=${2:-}
hold_start_seconds=${3:-300}
hold_seconds=${4:-600}
if [[ ! -f $trace || ! -f $load_start_file ]] || \
  [[ ! $hold_start_seconds =~ ^[0-9]+$ ]] || [[ ! $hold_seconds =~ ^[1-9][0-9]*$ ]]; then
  printf 'usage: bash scripts/summarize-queue-trace.sh TRACE LOAD_START_UTC [HOLD_START_SECONDS] [HOLD_SECONDS]\n' >&2
  exit 2
fi

load_start=$(<"$load_start_file")
TZ=UTC awk -v load_start="$load_start" -v hold_start="$hold_start_seconds" -v hold_length="$hold_seconds" '
function epoch(value, parsed) {
  parsed = value
  gsub(/[-T:Z]/, " ", parsed)
  return mktime(parsed)
}
function record_sample(   elapsed, backlog, in_hold, x) {
  if (timestamp == "" || ack == "" || pending == "" || sample_emitted) return
  elapsed = epoch(timestamp) - load_epoch
  backlog = pending + ack
  in_hold = elapsed >= hold_start && elapsed < hold_end
  print timestamp "\t" elapsed "\t" pending "\t" ack "\t" backlog "\t" in_hold
  sample_emitted = 1
  if (in_hold) {
    if (count == 0) {
      first = backlog
      first_elapsed = elapsed
    }
    last = backlog
    last_elapsed = elapsed
    if (count == 0 || backlog > maximum) maximum = backlog
    x = elapsed - hold_start
    sum_x += x
    sum_y += backlog
    sum_xy += x * backlog
    sum_xx += x * x
    count++
  }
}
BEGIN {
  load_epoch = epoch(load_start)
  hold_end = hold_start + hold_length
  print "timestamp\telapsed_s\tpending\tack_pending\tbacklog\tin_hold"
}
/^### [0-9]/ {
  timestamp = $2
  ack = ""
  pending = ""
  sample_emitted = 0
  next
}
/"num_ack_pending"[[:space:]]*:/ {
  ack = $2
  gsub(/[^0-9]/, "", ack)
  record_sample()
  next
}
/"num_pending"[[:space:]]*:/ {
  pending = $2
  gsub(/[^0-9]/, "", pending)
  record_sample()
}
/^worker_connections=/ {
  connections = $0
  sub(/^worker_connections=/, "", connections)
  elapsed = epoch(timestamp) - load_epoch
  if (connection_count == 0 || connections < connection_min) connection_min = connections
  if (connection_count == 0 || connections > connection_max) connection_max = connections
  connection_count++
  if (elapsed >= hold_start && elapsed < hold_end) {
    if (hold_connection_count == 0 || connections < hold_connection_min) hold_connection_min = connections
    if (hold_connection_count == 0 || connections > hold_connection_max) hold_connection_max = connections
    hold_connection_count++
  }
}
END {
  print ""
  print "hold_samples=" count
  if (count == 0) {
    print "ERROR: no hold samples found" > "/dev/stderr"
    exit 1
  }
  denominator = count * sum_xx - sum_x * sum_x
  slope = denominator == 0 ? 0 : (count * sum_xy - sum_x * sum_y) / denominator
  print "backlog_start=" first
  print "backlog_end=" last
  print "backlog_max=" maximum
  print "backlog_delta=" last - first
  print "hold_first_elapsed_s=" first_elapsed
  print "hold_last_elapsed_s=" last_elapsed
  printf "backlog_slope_per_second=%.6f\n", slope
  printf "one_batch_slope_tolerance=%.6f\n", 1000 / hold_length
  print "worker_connections_min=" connection_min
  print "worker_connections_max=" connection_max
  print "hold_worker_connections_min=" hold_connection_min
  print "hold_worker_connections_max=" hold_connection_max
  minimum_samples = int(hold_length / 2)
  if (minimum_samples < 2) minimum_samples = 2
  if (count < minimum_samples || first_elapsed > hold_start + 5 || last_elapsed < hold_end - 5) {
    print "ERROR: trace does not cover the hold closely enough" > "/dev/stderr"
    exit 1
  }
}
' "$trace"
