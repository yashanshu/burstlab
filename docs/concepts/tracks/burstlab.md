# Concept sequence: BurstLab queue-backed ingestion on AWS

**Track version:** 2
**Goal:** Explain and demonstrate the BurstLab system well enough to teach it to another backend developer: why the queue exists, why duplicate delivery is safe, why 15K RPS needs batching, where the trust boundaries are, how the infrastructure is created and destroyed, what it costs, and what a load-test result does and does not prove.
**Managed updates:** authorized

| # | Concept | Status | Lesson |
|---:|---|---|---|
| 1 | Queue-backed ingestion and the HTTP 202 boundary | passed | docs/concepts/queue-backed-ingestion-202-boundary.md |
| 2 | At-least-once delivery and idempotent batch writes | active | docs/concepts/at-least-once-delivery-idempotent-batch-writes.md |
| 3 | Micro-batching, long polling, and consumer throughput arithmetic | queued | — |
| 4 | Trust boundaries and least privilege in the request path | queued | — |
| 5 | Terraform's plan, state, and destroy model | queued | — |
| 6 | Private-by-default AWS networking | queued | — |
| 7 | Cost blast-radius control for a billable lab | queued | — |
| 8 | Verifying a running system without per-request logs | queued | — |
| 9 | Open-model load generation and honest reconciliation | queued | — |

**Source course:** burstlab_15k_aws_beginner_course.md
**Order:** follows the course. Concepts 1-4 need no AWS spend. Concepts 5-9 map to Parts V-VII.
