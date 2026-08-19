# BurstLab: Build, Secure, Deploy, and Load-Test a Queue-Backed API on AWS

**A standalone beginner course and small-book manuscript**  
**Version:** 1.0  
**Validated:** 19 August 2026  
**Region used:** AWS Asia Pacific (Mumbai), `ap-south-1`  
**Budget:** normally $5-10 for the capstone; stop at $20  
**Relationship to other documents:** none. This is an independent teaching project, not the production design in this repository.

## Read this before spending money

This course creates real billable AWS resources. It is designed to be completed and destroyed in the same study session.

The cost rules are:

1. Use a dedicated sandbox AWS account with no valuable data.
2. Create the small learning deployment first and destroy it before the burst lab.
3. Give the burst deployment a written two-hour destruction deadline.
4. Run only against the endpoint created by this course.
5. Do not enable per-request logs, NAT Gateway, WAF, API Gateway, Multi-AZ RDS, or backups for this synthetic lab.
6. Stop if the account estimate reaches $10; never deliberately continue past $20.
7. A budget alert can arrive late. It is not a hard spending cap. A timer and `terraform destroy` are the real controls.

This is a real, functioning system, but it is not a production template. The lab deliberately has one database, one AWS Region, one fixed course tenant, no public endpoint, no database backups, and no long-term support promise. The security chapter identifies every shortcut and the production replacement.

## What you will build

```text
Two k6 generators during the capstone
             |
             v
      internal AWS ALB
             |
             v
    1 small API in learning mode
    2 c7g.xlarge APIs in burst mode
             |
             v
       SQS Standard queue
             |
             v
    1 small worker in learning mode
    2 c7g.xlarge workers in burst mode
             |
             v
     private RDS PostgreSQL
```

The API authenticates and validates each request, groups up to ten events into one SQS API call, waits for SQS acknowledgement, and then returns HTTP `202`. Workers use long polling, write duplicate-safe database batches, commit, and only then delete SQS messages.

The public internet cannot reach the ALB, application port, worker, or database. Administration uses AWS Systems Manager rather than SSH. The load generators and endpoint live in the same VPC and Region.

## What you will learn

By the end, you should be able to explain and demonstrate:

- why an ingestion API puts a durable queue in front of its database;
- the difference between HTTP acceptance and completed processing;
- at-least-once delivery and idempotency;
- producer micro-batching, consumer long polling, and database batching;
- VPCs, subnets, route tables, security groups, IAM roles, ALB, SQS, RDS, S3, EC2 Auto Scaling, and Systems Manager;
- trust boundaries, local token verification, secret handling, TLS scope, least privilege, and input validation;
- infrastructure as code with Terraform;
- open-model load generation with k6;
- generator calibration, latency percentiles, dropped iterations, queue backlog, and result reconciliation;
- why a short 15K-RPS test is useful and what it does not prove;
- how to destroy every billable resource after the lesson.

## Suggested teaching schedule

| Lesson | Topic | Student time | AWS resources running? |
| --- | --- | ---: | --- |
| 1 | Mental model, cost, account safety | 30 min | No |
| 2 | Read and test the Go application | 60-90 min | No |
| 3 | Read and validate the Terraform | 60-90 min | No |
| 4 | Deploy one event end to end | 45-75 min | Yes, learning size |
| 5 | Security and failure exercises | 30-45 min | Yes, learning size |
| 6 | Destroy, inspect the bill, and discuss | 20 min | No |
| 7 | Optional 15K-RPS capstone | 60-90 min | Yes, burst size |
| 8 | Final teardown and interpretation | 30 min | No |

Do Lessons 1-6 before the capstone. The 15K test is optional because a new AWS account might not receive the necessary EC2 quota immediately.

# Part I - Understand the system before creating it

## 1. One request from beginning to end

A successful request takes this path:

1. k6 sends JSON and a bearer token to the internal ALB.
2. The ALB chooses a healthy API instance.
3. The API hashes the supplied token and compares it with the expected hash in constant time.
4. The API limits the body to 1 KiB and validates the fields and timestamp.
5. The API places the event into a five-millisecond in-process batching window.
6. The batcher calls `SendMessageBatch` with up to ten events.
7. Only events individually acknowledged by SQS receive HTTP `202`.
8. A worker receives up to ten messages per SQS poll.
9. The worker combines messages into database batches of up to 1,000.
10. It copies valid rows into a temporary staging table.
11. It inserts into the target table with `ON CONFLICT DO NOTHING`.
12. It commits the transaction.
13. Only after commit does it batch-delete the queue messages.

The important invariant is:

```text
No SQS acknowledgement -> no HTTP 202
No database commit     -> no SQS delete
```

If a worker crashes after commit but before delete, SQS eventually delivers the message again. The database primary key suppresses the duplicate. This is at-least-once delivery made safe with idempotency.

## 2. Why the queue exists

Without a queue, a traffic burst immediately becomes a database burst. With a queue, the API can accept quickly while workers write at the sustainable database rate. Queue depth is not automatically bad; an increasing age of the oldest message tells you whether the system is falling behind.

The queue does not make capacity unlimited. If workers remain slower than average ingress forever, backlog grows forever. The capstone therefore measures both API acceptance and post-test drain.

## 3. Why this lab is inexpensive

The system is disposable and omits fixed-cost components that do not teach the core data path:

- no NAT Gateway;
- no Kubernetes;
- no WAF or API Gateway;
- no public DNS name or certificate requirement;
- no per-request CloudWatch logs;
- no Multi-AZ database or long-lived backup;
- no permanent performance environment.

Application instances have public IP addresses only for outbound package and AWS API access. Their security groups permit no public inbound traffic. The database has no public endpoint.

## 4. Expected capstone cost

The two-generator script produces approximately 10.56 million events:

```text
Per generator:
500 RPS x 120 seconds                         =    60,000
average 4,000 RPS during the 3-minute ramp   =   720,000
7,500 RPS x 600-second hold                  = 4,500,000
                                                   ---------
                                                   5,280,000

Two generators                                    10,560,000
```

When send, receive, and delete calls average ten messages per action:

```text
10.56M events x 3 actions / 10 x 1.10 overhead
= about 3.48M SQS requests

3.48M x $0.40 per million
= about $1.39
```

Planning estimate for a deployment that exists for no more than two hours:

| Item | Expected cost |
| --- | ---: |
| Six `c7g.xlarge` instances: 2 API, 2 worker, 2 generator | $1-2 |
| Single-AZ `db.r7g.xlarge` plus 400-GiB gp3 | $1-2 |
| SQS requests | $1-2 |
| ALB hours and LCUs | Under $1 |
| Root disks, public IPv4, S3, Secrets Manager, and other small usage | $1-3 |
| **Expected total** | **$5-10** |
| **Stop condition** | **$20** |

Prices vary. Re-price immediately before teaching. If batching is broken, generators run longer, resources fail to delete, or logs are enabled per request, cost rises.

# Part II - Prepare a safe workstation and AWS account

## 5. Prerequisites

You need:

- an AWS sandbox account;
- Go 1.24 or later;
- Terraform 1.14 or later;
- AWS CLI v2;
- the AWS Session Manager plugin;
- Git, OpenSSL, a terminal, and a text editor;
- approximately four local CPU cores and 2 GB of free disk for builds and provider downloads.

Install from the official guides rather than copying third-party installer commands:

- Go: <https://go.dev/doc/install>
- Terraform: <https://developer.hashicorp.com/terraform/install>
- AWS CLI v2: <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html>
- Session Manager plugin: <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>

Check the tools:

```bash
go version
terraform version
aws --version
session-manager-plugin --version
openssl version
```

**Checkpoint:** every command prints a version. Do not create AWS resources yet.

## 6. Secure the AWS account first

1. Enable MFA on the root user.
2. Do not create root access keys.
3. Use IAM Identity Center or another role-based identity with temporary credentials.
4. Use a dedicated sandbox account, not an employer's production account.
5. In AWS Billing, create a monthly cost budget alert at $10 and another at $20.
6. Record a phone or calendar alarm for two hours after the burst deployment begins.

For a personal teaching account, the human deploying Terraform needs broad permissions to create the lab resources. That is bootstrap access, not the permissions used by the application. The EC2 roles created later are narrowly scoped.

Configure a temporary AWS CLI profile:

```bash
aws configure sso --profile burstlab
aws sso login --profile burstlab
export AWS_PROFILE=burstlab
export AWS_REGION=ap-south-1
aws sts get-caller-identity
```

PowerShell equivalents are `$env:AWS_PROFILE="burstlab"` and `$env:AWS_REGION="ap-south-1"`.

**Checkpoint:** `get-caller-identity` shows the sandbox account ID you intend to charge. Stop if it shows any other account.

## 7. Check the capstone quota before writing code

The capstone uses six `c7g.xlarge` EC2 instances, or 24 Standard-family vCPUs. New accounts often have lower quotas.

```bash
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --query 'Quota.Value'
```

If the value is below 24:

- request 24 vCPUs in Service Quotas now;
- continue through the learning deployment while waiting;
- if AWS does not grant it, run a proportional test such as 1,500 RPS and label the result honestly;
- do not spread instances across accounts or use unrelated services to evade the quota.

Also read the current Amazon EC2 Testing Policy. This course sends ordinary application traffic only to your own target in the same AWS Region. It is not a DDoS exercise.

## 8. Create the course project

Create a new directory outside any production project:

```bash
mkdir -p burstlab-course/app burstlab-course/dist burstlab-course/infra burstlab-course/load
cd burstlab-course
```

The finished layout is:

```text
burstlab-course/
├── app/
│   ├── main.go
│   └── main_test.go
├── dist/
│   └── burstlab                 # generated Linux ARM64 binary
├── go.mod
├── go.sum                       # generated by go mod tidy
├── infra/
│   ├── app_user_data.sh.tftpl
│   ├── loadgen_user_data.sh.tftpl
│   ├── main.tf
│   ├── outputs.tf
│   ├── variables.tf
│   └── versions.tf
└── load/
    └── load.js
```

# Part III - Build the application

## 9. Create `go.mod`

Put the following in `go.mod`. These are the versions used to validate this manuscript.

```go
module burstlab

go 1.24.0

require (
	github.com/aws/aws-sdk-go-v2/config v1.31.16
	github.com/aws/aws-sdk-go-v2/service/secretsmanager v1.39.6
	github.com/aws/aws-sdk-go-v2/service/sqs v1.42.16
	github.com/jackc/pgx/v5 v5.7.6
)

require (
	github.com/aws/aws-sdk-go-v2 v1.40.0 // indirect
	github.com/aws/aws-sdk-go-v2/credentials v1.18.20 // indirect
	github.com/aws/aws-sdk-go-v2/feature/ec2/imds v1.18.12 // indirect
	github.com/aws/aws-sdk-go-v2/internal/configsources v1.4.14 // indirect
	github.com/aws/aws-sdk-go-v2/internal/endpoints/v2 v2.7.14 // indirect
	github.com/aws/aws-sdk-go-v2/internal/ini v1.8.4 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/accept-encoding v1.13.2 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/presigned-url v1.13.12 // indirect
	github.com/aws/aws-sdk-go-v2/service/sso v1.30.0 // indirect
	github.com/aws/aws-sdk-go-v2/service/ssooidc v1.35.4 // indirect
	github.com/aws/aws-sdk-go-v2/service/sts v1.39.0 // indirect
	github.com/aws/smithy-go v1.23.2 // indirect
	github.com/jackc/pgpassfile v1.0.0 // indirect
	github.com/jackc/pgservicefile v0.0.0-20240606120523-5a60cdf6a761 // indirect
	github.com/jackc/puddle/v2 v2.2.2 // indirect
	golang.org/x/crypto v0.37.0 // indirect
	golang.org/x/sync v0.13.0 // indirect
	golang.org/x/text v0.24.0 // indirect
)
```

Then download the modules and generate `go.sum`:

```bash
go mod tidy
```

What each direct dependency does:

- AWS config discovers the EC2 instance role and Region without stored access keys.
- The SQS client publishes, receives, and deletes messages.
- The Secrets Manager client reads the RDS-generated password at process startup.
- pgx supplies PostgreSQL pooling, transactions, and `COPY`.

## 10. Create `app/main.go`

```go
package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	sqstypes "github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type event struct {
	RequestID string    `json:"request_id"`
	EventTS   time.Time `json:"event_ts"`
	Value     string    `json:"value"`
}

type envelope struct {
	TenantID  string    `json:"tenant_id"`
	RequestID string    `json:"request_id"`
	EventTS   time.Time `json:"event_ts"`
	Value     string    `json:"value"`
}

type submission struct {
	body   string
	result chan error
}

type stats struct {
	accepted   atomic.Uint64
	rejected   atomic.Uint64
	committed  atomic.Uint64
	duplicates atomic.Uint64
	quarantine atomic.Uint64
	deleted    atomic.Uint64
	errors     atomic.Uint64
}

type batcher struct {
	client   *sqs.Client
	queueURL string
	in       chan submission
	stats    *stats
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	awsConfig, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		log.Fatal(err)
	}

	mode := env("BURSTLAB_MODE", "")
	s := &stats{}
	go logStats(ctx, s)

	switch mode {
	case "api":
		err = runAPI(ctx, sqs.NewFromConfig(awsConfig), s)
	case "worker":
		err = runWorker(ctx, sqs.NewFromConfig(awsConfig), secretsmanager.NewFromConfig(awsConfig), s)
	case "count":
		err = printCounts(ctx, secretsmanager.NewFromConfig(awsConfig))
	default:
		err = fmt.Errorf("BURSTLAB_MODE must be api, worker, or count")
	}
	if err != nil && !errors.Is(err, context.Canceled) {
		log.Fatal(err)
	}
}

func runAPI(ctx context.Context, client *sqs.Client, s *stats) error {
	queueURL := mustEnv("QUEUE_URL")
	if _, err := client.GetQueueAttributes(ctx, &sqs.GetQueueAttributesInput{QueueUrl: &queueURL}); err != nil {
		return fmt.Errorf("check queue: %w", err)
	}

	b := &batcher{client: client, queueURL: queueURL, in: make(chan submission, 4096), stats: s}
	go b.run(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("/health/live", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/health/ready", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/stats", func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]uint64{
			"accepted": s.accepted.Load(), "rejected": s.rejected.Load(), "errors": s.errors.Load(),
		})
	})
	mux.HandleFunc("/v1/events", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !authorized(r.Header.Get("Authorization"), mustEnv("TOKEN_SHA256")) {
			s.rejected.Add(1)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()
		var input event
		if err := dec.Decode(&input); err != nil {
			s.rejected.Add(1)
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		if err := dec.Decode(&struct{}{}); err != io.EOF {
			s.rejected.Add(1)
			http.Error(w, "one JSON object required", http.StatusBadRequest)
			return
		}
		if err := validateEvent(input, time.Now()); err != nil {
			s.rejected.Add(1)
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		message, _ := json.Marshal(envelope{
			TenantID: "course-tenant", RequestID: input.RequestID, EventTS: input.EventTS, Value: input.Value,
		})
		job := submission{body: string(message), result: make(chan error, 1)}
		select {
		case b.in <- job:
		case <-r.Context().Done():
			return
		}
		select {
		case err := <-job.result:
			if err != nil {
				s.errors.Add(1)
				w.Header().Set("Retry-After", "1")
				http.Error(w, "queue unavailable", http.StatusServiceUnavailable)
				return
			}
			s.accepted.Add(1)
			w.WriteHeader(http.StatusAccepted)
		case <-r.Context().Done():
			return
		}
	})

	server := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       3 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	log.Printf("api listening on %s", server.Addr)
	err := server.ListenAndServe()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func (b *batcher) run(ctx context.Context) {
	for {
		var first submission
		select {
		case first = <-b.in:
		case <-ctx.Done():
			return
		}
		batch := []submission{first}
		timer := time.NewTimer(5 * time.Millisecond)
	collect:
		for len(batch) < 10 {
			select {
			case item := <-b.in:
				batch = append(batch, item)
			case <-timer.C:
				break collect
			case <-ctx.Done():
				break collect
			}
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		b.flush(batch)
	}
}

func (b *batcher) flush(batch []submission) {
	entries := make([]sqstypes.SendMessageBatchRequestEntry, len(batch))
	for i, item := range batch {
		id := strconv.Itoa(i)
		entries[i] = sqstypes.SendMessageBatchRequestEntry{Id: &id, MessageBody: &item.body}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := b.client.SendMessageBatch(ctx, &sqs.SendMessageBatchInput{QueueUrl: &b.queueURL, Entries: entries})
	if err != nil {
		for _, item := range batch {
			item.result <- err
		}
		return
	}
	failed := make(map[string]error, len(out.Failed))
	for _, failure := range out.Failed {
		failed[value(failure.Id)] = fmt.Errorf("%s: %s", value(failure.Code), value(failure.Message))
	}
	succeeded := make(map[string]bool, len(out.Successful))
	for _, success := range out.Successful {
		succeeded[value(success.Id)] = true
	}
	for i, item := range batch {
		id := strconv.Itoa(i)
		if failure, ok := failed[id]; ok {
			item.result <- failure
		} else if succeeded[id] {
			item.result <- nil
		} else {
			item.result <- errors.New("SQS omitted batch item result")
		}
	}
}

func runWorker(ctx context.Context, client *sqs.Client, secrets *secretsmanager.Client, s *stats) error {
	dbURL, err := databaseURL(ctx, secrets)
	if err != nil {
		return err
	}
	poolConfig, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		return err
	}
	poolConfig.MaxConns = 8
	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		return fmt.Errorf("database ping: %w", err)
	}
	if err := migrate(ctx, pool); err != nil {
		return err
	}

	queueURL := mustEnv("QUEUE_URL")
	messages := make(chan sqstypes.Message, 20000)
	acks := make(chan sqstypes.Message, 20000)
	for i := 0; i < 32; i++ {
		go receiveLoop(ctx, client, queueURL, messages, s)
		go deleteLoop(ctx, client, queueURL, acks, s)
	}
	for i := 0; i < 4; i++ {
		go writeLoop(ctx, pool, messages, acks, s)
	}
	log.Printf("worker started")
	<-ctx.Done()
	return nil
}

func receiveLoop(ctx context.Context, client *sqs.Client, queueURL string, messages chan<- sqstypes.Message, s *stats) {
	for ctx.Err() == nil {
		out, err := client.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl: &queueURL, MaxNumberOfMessages: 10, WaitTimeSeconds: 20, VisibilityTimeout: 120,
		})
		if err != nil {
			if ctx.Err() == nil {
				s.errors.Add(1)
				time.Sleep(time.Second)
			}
			continue
		}
		for _, message := range out.Messages {
			select {
			case messages <- message:
			case <-ctx.Done():
				return
			}
		}
	}
}

func writeLoop(ctx context.Context, pool *pgxpool.Pool, messages <-chan sqstypes.Message, acks chan<- sqstypes.Message, s *stats) {
	for {
		var first sqstypes.Message
		select {
		case first = <-messages:
		case <-ctx.Done():
			return
		}
		batch := []sqstypes.Message{first}
		timer := time.NewTimer(50 * time.Millisecond)
	collect:
		for len(batch) < 1000 {
			select {
			case message := <-messages:
				batch = append(batch, message)
			case <-timer.C:
				break collect
			case <-ctx.Done():
				break collect
			}
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		if err := writeBatch(ctx, pool, batch, s); err != nil {
			s.errors.Add(1)
			log.Printf("database batch failed: %v", err)
			continue
		}
		for _, message := range batch {
			select {
			case acks <- message:
			case <-ctx.Done():
				return
			}
		}
	}
}

func writeBatch(ctx context.Context, pool *pgxpool.Pool, messages []sqstypes.Message, s *stats) error {
	valid := make([]envelope, 0, len(messages))
	type badMessage struct{ body, reason string }
	bad := make([]badMessage, 0)
	for _, message := range messages {
		var item envelope
		if err := json.Unmarshal([]byte(value(message.Body)), &item); err != nil || item.TenantID == "" || item.RequestID == "" || item.EventTS.IsZero() {
			bad = append(bad, badMessage{body: value(message.Body), reason: "invalid queue envelope"})
			continue
		}
		valid = append(valid, item)
	}

	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `CREATE TEMP TABLE IF NOT EXISTS stage_events
		(tenant_id text, request_id text, event_ts timestamptz, value text) ON COMMIT DELETE ROWS`); err != nil {
		return err
	}
	if len(valid) > 0 {
		rows := make([][]any, len(valid))
		for i, item := range valid {
			rows[i] = []any{item.TenantID, item.RequestID, item.EventTS, item.Value}
		}
		if _, err = tx.CopyFrom(ctx, pgx.Identifier{"stage_events"}, []string{"tenant_id", "request_id", "event_ts", "value"}, pgx.CopyFromRows(rows)); err != nil {
			return err
		}
	}
	tag, err := tx.Exec(ctx, `INSERT INTO events (tenant_id, request_id, event_ts, value)
		SELECT tenant_id, request_id, event_ts, value FROM stage_events
		ON CONFLICT DO NOTHING`)
	if err != nil {
		return err
	}
	for _, item := range bad {
		if _, err = tx.Exec(ctx, `INSERT INTO quarantine (payload, reason) VALUES ($1, $2)`, item.body, item.reason); err != nil {
			return err
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return err
	}
	inserted := uint64(tag.RowsAffected())
	s.committed.Add(inserted)
	s.duplicates.Add(uint64(len(valid)) - inserted)
	s.quarantine.Add(uint64(len(bad)))
	return nil
}

func deleteLoop(ctx context.Context, client *sqs.Client, queueURL string, acks <-chan sqstypes.Message, s *stats) {
	for {
		var first sqstypes.Message
		select {
		case first = <-acks:
		case <-ctx.Done():
			return
		}
		batch := []sqstypes.Message{first}
		timer := time.NewTimer(5 * time.Millisecond)
	collect:
		for len(batch) < 10 {
			select {
			case message := <-acks:
				batch = append(batch, message)
			case <-timer.C:
				break collect
			case <-ctx.Done():
				break collect
			}
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		entries := make([]sqstypes.DeleteMessageBatchRequestEntry, len(batch))
		for i, message := range batch {
			id := strconv.Itoa(i)
			entries[i] = sqstypes.DeleteMessageBatchRequestEntry{Id: &id, ReceiptHandle: message.ReceiptHandle}
		}
		out, err := client.DeleteMessageBatch(ctx, &sqs.DeleteMessageBatchInput{QueueUrl: &queueURL, Entries: entries})
		if err != nil {
			s.errors.Add(1)
			continue
		}
		s.deleted.Add(uint64(len(out.Successful)))
		s.errors.Add(uint64(len(out.Failed)))
	}
}

func migrate(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS events (
			tenant_id text NOT NULL,
			request_id text NOT NULL,
			event_ts timestamptz NOT NULL,
			value text NOT NULL,
			accepted_at timestamptz NOT NULL DEFAULT now(),
			PRIMARY KEY (tenant_id, request_id, event_ts)
		);
		CREATE TABLE IF NOT EXISTS quarantine (
			id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
			payload text NOT NULL,
			reason text NOT NULL,
			created_at timestamptz NOT NULL DEFAULT now()
		);`)
	return err
}

func printCounts(ctx context.Context, secrets *secretsmanager.Client) error {
	dbURL, err := databaseURL(ctx, secrets)
	if err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		return err
	}
	defer pool.Close()
	var events, quarantine int64
	if err = pool.QueryRow(ctx, `SELECT count(*) FROM events`).Scan(&events); err != nil {
		return err
	}
	if err = pool.QueryRow(ctx, `SELECT count(*) FROM quarantine`).Scan(&quarantine); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]int64{"events": events, "quarantine": quarantine})
}

func databaseURL(ctx context.Context, client *secretsmanager.Client) (string, error) {
	secretARN := mustEnv("DB_SECRET_ARN")
	out, err := client.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{SecretId: &secretARN})
	if err != nil {
		return "", fmt.Errorf("read database secret: %w", err)
	}
	var secret struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := json.Unmarshal([]byte(value(out.SecretString)), &secret); err != nil {
		return "", err
	}
	u := &url.URL{
		Scheme: "postgres",
		User:   url.UserPassword(secret.Username, secret.Password),
		Host:   net.JoinHostPort(mustEnv("DB_HOST"), "5432"),
		Path:   "/" + env("DB_NAME", "burstlab"),
	}
	query := u.Query()
	query.Set("sslmode", "verify-full")
	query.Set("sslrootcert", env("RDS_CA_FILE", "/opt/burstlab/global-bundle.pem"))
	u.RawQuery = query.Encode()
	return u.String(), nil
}

func authorized(header, expectedHex string) bool {
	if !strings.HasPrefix(header, "Bearer ") {
		return false
	}
	expected, err := hex.DecodeString(expectedHex)
	if err != nil || len(expected) != sha256.Size {
		return false
	}
	actual := sha256.Sum256([]byte(strings.TrimPrefix(header, "Bearer ")))
	return subtle.ConstantTimeCompare(actual[:], expected) == 1
}

func validateEvent(input event, now time.Time) error {
	if len(input.RequestID) < 1 || len(input.RequestID) > 64 {
		return errors.New("request_id must contain 1-64 characters")
	}
	for _, char := range input.RequestID {
		if !(char == '-' || char == '_' || char >= '0' && char <= '9' || char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z') {
			return errors.New("request_id contains an unsupported character")
		}
	}
	if input.EventTS.Before(now.Add(-24*time.Hour)) || input.EventTS.After(now.Add(24*time.Hour)) {
		return errors.New("event_ts must be within 24 hours")
	}
	if len(input.Value) > 256 {
		return errors.New("value is longer than 256 characters")
	}
	return nil
}

func logStats(ctx context.Context, s *stats) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			log.Printf("stats accepted=%d rejected=%d committed=%d duplicates=%d quarantine=%d deleted=%d errors=%d",
				s.accepted.Load(), s.rejected.Load(), s.committed.Load(), s.duplicates.Load(),
				s.quarantine.Load(), s.deleted.Load(), s.errors.Load())
		case <-ctx.Done():
			return
		}
	}
}

func value(pointer *string) string {
	if pointer == nil {
		return ""
	}
	return *pointer
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func mustEnv(name string) string {
	value := os.Getenv(name)
	if value == "" {
		log.Fatalf("%s is required", name)
	}
	return value
}
```

### Read the important sections

Do not treat the file as magic. Find these functions and explain them aloud:

- `authorized`: hashes a bearer token and uses constant-time comparison.
- `validateEvent`: rejects bad identifiers, clock skew, and oversized values.
- `batcher.run` and `batcher.flush`: create producer batches and inspect partial SQS failures.
- `receiveLoop`: uses 20-second SQS long polling.
- `writeBatch`: stages rows, inserts with conflict handling, and commits.
- `deleteLoop`: deletes only committed messages and batches acknowledgements.
- `databaseURL`: reads an RDS-managed secret and requires certificate verification.

The API never receives `tenant_id` from the request body. This one-tenant course assigns `course-tenant` after authentication. A multi-tenant system would take the tenant from a verified token claim.

## 11. Create `app/main_test.go`

```go
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
	"time"
)

func TestAuthorization(t *testing.T) {
	sum := sha256.Sum256([]byte("course-secret"))
	hash := hex.EncodeToString(sum[:])
	if !authorized("Bearer course-secret", hash) {
		t.Fatal("valid token was rejected")
	}
	if authorized("Bearer wrong", hash) {
		t.Fatal("invalid token was accepted")
	}
}

func TestEventValidation(t *testing.T) {
	now := time.Now()
	if err := validateEvent(event{RequestID: "event-1", EventTS: now, Value: "ok"}, now); err != nil {
		t.Fatalf("valid event failed: %v", err)
	}
	if err := validateEvent(event{RequestID: "bad id", EventTS: now}, now); err == nil {
		t.Fatal("invalid request_id passed")
	}
	if err := validateEvent(event{RequestID: "event-2", EventTS: now.Add(25 * time.Hour)}, now); err == nil {
		t.Fatal("future event passed")
	}
}
```

Run the fast checks:

```bash
go test ./...
go vet ./...
```

**Checkpoint:** tests pass. The first proves that a wrong token cannot authenticate. The second proves basic event-boundary validation.

## 12. Build the AWS binary

Amazon Linux instances in this course use ARM64 Graviton processors. Go can cross-compile a static binary from an Intel, AMD, or ARM workstation:

```bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -trimpath -ldflags='-s -w' -o dist/burstlab ./app
file dist/burstlab
```

Expected output includes `ARM aarch64` and `statically linked`.

Why one binary? `BURSTLAB_MODE=api` starts the HTTP service, `worker` starts consumers, and `count` prints database totals. One artefact removes version drift between API and worker.

# Part IV - Build the load test

## 13. Create `load/load.js`

```javascript
import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';

const targetRPS = Number(__ENV.TARGET_RPS || 7500);
const calibrate = __ENV.PROFILE === 'calibrate';
const stages = calibrate
  ? [
      { target: targetRPS, duration: '30s' },
      { target: targetRPS, duration: '1m' },
    ]
  : [
      { target: Math.max(1, Math.floor(targetRPS / 15)), duration: '2m' },
      { target: targetRPS, duration: '3m' },
      { target: targetRPS, duration: '10m' },
    ];

export const options = {
  discardResponseBodies: true,
  scenarios: {
    burst: {
      executor: 'ramping-arrival-rate',
      startRate: Math.max(1, Math.floor(targetRPS / 15)),
      timeUnit: '1s',
      preAllocatedVUs: 1000,
      maxVUs: 3000,
      stages,
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.005'],
    http_req_duration: ['p(95)<150'],
    dropped_iterations: ['count==0'],
  },
};

export default function () {
  if (calibrate) {
    const response = http.get(`${__ENV.URL}/health/live`, { timeout: '2s' });
    check(response, { healthy: (result) => result.status === 200 });
    return;
  }
  const requestID = `${__ENV.GENERATOR_ID}-${exec.scenario.iterationInTest}`;
  const response = http.post(
    `${__ENV.URL}/v1/events`,
    JSON.stringify({
      request_id: requestID,
      event_ts: new Date().toISOString(),
      value: 'course-event',
    }),
    {
      headers: {
        Authorization: `Bearer ${__ENV.TOKEN}`,
        'Content-Type': 'application/json',
      },
      timeout: '2s',
    },
  );
  check(response, { accepted: (result) => result.status === 202 });
}
```

The k6 arrival-rate executor schedules requests independently of response completion. A closed model can hide overload because slow responses automatically reduce the request rate. This open model instead reports dropped iterations when the generators cannot maintain the target.

Each of two generators receives `TARGET_RPS=7500`, producing 15K RPS in aggregate. `GENERATOR_ID` prevents request-ID collisions between generator machines.

There are two profiles:

- `PROFILE=calibrate`: call only `/health/live`, ramp to the target, and hold for one minute. This tests the generators, ALB, and HTTP tier without paying for SQS/database events.
- default: 2-minute 1K aggregate start, 3-minute ramp, then 10 minutes at 15K aggregate RPS.

The provisional thresholds are less than 0.5% failed requests, p95 under 150 ms, and zero dropped iterations. They are teaching targets, not universal service-level objectives.

# Part V - Define the AWS infrastructure

## 14. Why Terraform

Clicking through a console can create the lab, but it cannot reliably show a learner what exists or delete it all. Terraform turns the infrastructure into reviewable files and gives this course one cleanup command.

Terraform state can contain sensitive values. This lab passes only a token hash to Terraform and lets RDS generate its own password in Secrets Manager. Keep the local state out of public source control. A team project would use an encrypted remote backend with locking and restricted access.

## 15. Create `infra/versions.tf`

```hcl
terraform {
  required_version = ">= 1.14, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.60.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "burstlab-course"
      Environment = var.burst_mode ? "burst" : "learning"
      ExpiresAt   = var.expires_at
    }
  }
}
```

The exact provider version is intentional. Upgrade only after re-running `terraform validate` and the course tests.

## 16. Create `infra/variables.tf`

```hcl
variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "burst_mode" {
  type    = bool
  default = false
}

variable "burst_loadgen_count" {
  type        = number
  default     = 2
  description = "Use 2 first; use 4 only if generator calibration fails and the EC2 quota allows it."

  validation {
    condition     = contains([2, 4], var.burst_loadgen_count)
    error_message = "burst_loadgen_count must be 2 or 4."
  }
}

variable "expires_at" {
  type        = string
  description = "Human-readable UTC destruction deadline, for example 2026-08-19T18:00:00Z."
}

variable "token_sha256" {
  type        = string
  sensitive   = true
  description = "SHA-256 hex digest of the course bearer token; never pass the plaintext token to Terraform."

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.token_sha256))
    error_message = "token_sha256 must be 64 lowercase hexadecimal characters."
  }
}

variable "app_binary_path" {
  type    = string
  default = "../dist/burstlab"
}

variable "load_script_path" {
  type    = string
  default = "../load/load.js"
}
```

`burst_mode=false` creates one tiny API and one tiny worker with no generators. `burst_mode=true` creates two API instances, two workers, two generators, and the larger RDS class.

The `expires_at` value is a visible tag, not an automatic deletion mechanism. A human still owns teardown.

## 17. Create `infra/main.tf`

```hcl
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  azs            = slice(data.aws_availability_zones.available.names, 0, 2)
  api_count      = var.burst_mode ? 2 : 1
  worker_count   = var.burst_mode ? 2 : 1
  loadgen_count  = var.burst_mode ? var.burst_loadgen_count : 0
  app_type       = var.burst_mode ? "c7g.xlarge" : "t4g.micro"
  db_class       = var.burst_mode ? "db.r7g.xlarge" : "db.t4g.micro"
  db_storage_gib = var.burst_mode ? 400 : 20
  artifact_key   = "builds/burstlab"
  load_key       = "load/load.js"
  token_path     = "/burstlab/course-token"
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "burstlab" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
}

resource "aws_subnet" "app" {
  count                   = 2
  vpc_id                  = aws_vpc.lab.id
  availability_zone       = local.azs[count.index]
  cidr_block              = cidrsubnet(aws_vpc.lab.cidr_block, 8, count.index)
  map_public_ip_on_launch = true

  tags = { Name = "burstlab-app-${count.index + 1}" }
}

resource "aws_subnet" "db" {
  count             = 2
  vpc_id            = aws_vpc.lab.id
  availability_zone = local.azs[count.index]
  cidr_block        = cidrsubnet(aws_vpc.lab.cidr_block, 8, count.index + 10)

  tags = { Name = "burstlab-db-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
}

resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "loadgen" {
  name   = "burstlab-loadgen"
  vpc_id = aws_vpc.lab.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "alb" {
  name   = "burstlab-alb"
  vpc_id = aws_vpc.lab.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.loadgen.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "api" {
  name   = "burstlab-api"
  vpc_id = aws_vpc.lab.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "worker" {
  name   = "burstlab-worker"
  vpc_id = aws_vpc.lab.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name   = "burstlab-db"
  vpc_id = aws_vpc.lab.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.worker.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_s3_bucket" "artifacts" {
  bucket        = "burstlab-course-${data.aws_caller_identity.current.account_id}-${var.region}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "app" {
  bucket      = aws_s3_bucket.artifacts.id
  key         = local.artifact_key
  source      = var.app_binary_path
  source_hash = filemd5(var.app_binary_path)

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.artifacts]
}

resource "aws_s3_object" "load" {
  bucket      = aws_s3_bucket.artifacts.id
  key         = local.load_key
  source      = var.load_script_path
  source_hash = filemd5(var.load_script_path)

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.artifacts]
}

resource "aws_sqs_queue" "events" {
  name                       = "burstlab-events"
  message_retention_seconds  = 3600
  visibility_timeout_seconds = 120
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
}

resource "aws_db_subnet_group" "events" {
  name       = "burstlab-events"
  subnet_ids = aws_subnet.db[*].id
}

resource "aws_db_instance" "events" {
  identifier                  = "burstlab-events"
  engine                      = "postgres"
  instance_class              = local.db_class
  allocated_storage           = local.db_storage_gib
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = "burstlab"
  username                    = "burstadmin"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.events.name
  vpc_security_group_ids      = [aws_security_group.db.id]
  publicly_accessible         = false
  multi_az                    = false
  backup_retention_period     = 0
  deletion_protection         = false
  skip_final_snapshot         = true
  apply_immediately           = true
  auto_minor_version_upgrade  = true
}

resource "aws_lb" "api" {
  name                       = "burstlab-api"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = aws_subnet.app[*].id
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "api" {
  name                 = "burstlab-api"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.lab.id
  deregistration_delay = 15

  health_check {
    path                = "/health/ready"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 8080
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api" {
  name               = "burstlab-api"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role" "worker" {
  name               = "burstlab-worker"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role" "loadgen" {
  name               = "burstlab-loadgen"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "api_ssm" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "worker_ssm" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "loadgen_ssm" {
  role       = aws_iam_role.loadgen.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "api" {
  statement {
    actions   = ["s3:GetObject"]
    resources = [aws_s3_object.app.arn]
  }
  statement {
    actions   = ["sqs:GetQueueAttributes", "sqs:SendMessage"]
    resources = [aws_sqs_queue.events.arn]
  }
}

data "aws_iam_policy_document" "worker" {
  statement {
    actions   = ["s3:GetObject"]
    resources = [aws_s3_object.app.arn]
  }
  statement {
    actions = [
      "sqs:ChangeMessageVisibility",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.events.arn]
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.events.master_user_secret[0].secret_arn]
  }
}

data "aws_iam_policy_document" "loadgen" {
  statement {
    actions   = ["s3:GetObject"]
    resources = [aws_s3_object.load.arn]
  }
  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.token_path}"
    ]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "burstlab-api"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

resource "aws_iam_role_policy" "worker" {
  name   = "burstlab-worker"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

resource "aws_iam_role_policy" "loadgen" {
  name   = "burstlab-loadgen"
  role   = aws_iam_role.loadgen.id
  policy = data.aws_iam_policy_document.loadgen.json
}

resource "aws_iam_instance_profile" "api" {
  name = "burstlab-api"
  role = aws_iam_role.api.name
}

resource "aws_iam_instance_profile" "worker" {
  name = "burstlab-worker"
  role = aws_iam_role.worker.name
}

resource "aws_iam_instance_profile" "loadgen" {
  name = "burstlab-loadgen"
  role = aws_iam_role.loadgen.name
}

resource "aws_launch_template" "api" {
  name_prefix   = "burstlab-api-"
  image_id      = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = local.app_type
  user_data = base64encode(templatefile("${path.module}/app_user_data.sh.tftpl", {
    role          = "api"
    region        = var.region
    bucket        = aws_s3_bucket.artifacts.id
    artifact_key  = local.artifact_key
    queue_url     = aws_sqs_queue.events.url
    token_hash    = var.token_sha256
    db_host       = ""
    db_secret_arn = ""
  }))
  vpc_security_group_ids = [aws_security_group.api.id]

  iam_instance_profile { name = aws_iam_instance_profile.api.name }
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "burstlab-api", Role = "api" }
  }
}

resource "aws_launch_template" "worker" {
  name_prefix   = "burstlab-worker-"
  image_id      = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = local.app_type
  user_data = base64encode(templatefile("${path.module}/app_user_data.sh.tftpl", {
    role          = "worker"
    region        = var.region
    bucket        = aws_s3_bucket.artifacts.id
    artifact_key  = local.artifact_key
    queue_url     = aws_sqs_queue.events.url
    token_hash    = ""
    db_host       = aws_db_instance.events.address
    db_secret_arn = aws_db_instance.events.master_user_secret[0].secret_arn
  }))
  vpc_security_group_ids = [aws_security_group.worker.id]

  iam_instance_profile { name = aws_iam_instance_profile.worker.name }
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "burstlab-worker", Role = "worker" }
  }
}

resource "aws_launch_template" "loadgen" {
  name_prefix   = "burstlab-loadgen-"
  image_id      = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = local.app_type
  user_data = base64encode(templatefile("${path.module}/loadgen_user_data.sh.tftpl", {
    region   = var.region
    bucket   = aws_s3_bucket.artifacts.id
    load_key = local.load_key
  }))
  vpc_security_group_ids = [aws_security_group.loadgen.id]

  iam_instance_profile { name = aws_iam_instance_profile.loadgen.name }
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "burstlab-loadgen", Role = "loadgen" }
  }
}

resource "aws_autoscaling_group" "api" {
  name                = "burstlab-api"
  min_size            = local.api_count
  desired_capacity    = local.api_count
  max_size            = local.api_count
  vpc_zone_identifier = aws_subnet.app[*].id
  target_group_arns   = [aws_lb_target_group.api.arn]
  health_check_type   = "ELB"

  launch_template {
    id      = aws_launch_template.api.id
    version = "$Latest"
  }

  depends_on = [aws_iam_role_policy.api, aws_s3_object.app]
}

resource "aws_autoscaling_group" "worker" {
  name                = "burstlab-worker"
  min_size            = local.worker_count
  desired_capacity    = local.worker_count
  max_size            = local.worker_count
  vpc_zone_identifier = aws_subnet.app[*].id

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  depends_on = [aws_iam_role_policy.worker, aws_s3_object.app]
}

resource "aws_autoscaling_group" "loadgen" {
  name                = "burstlab-loadgen"
  min_size            = local.loadgen_count
  desired_capacity    = local.loadgen_count
  max_size            = local.loadgen_count
  vpc_zone_identifier = aws_subnet.app[*].id

  launch_template {
    id      = aws_launch_template.loadgen.id
    version = "$Latest"
  }

  depends_on = [aws_iam_role_policy.loadgen, aws_s3_object.load]
}
```

### Read the infrastructure in layers

1. **Network:** one VPC, two application subnets with internet routes, and two isolated database subnets.
2. **Security groups:** generators may reach the internal ALB; the ALB may reach APIs; workers may reach PostgreSQL. There is no inbound SSH rule.
3. **S3:** a private encrypted bucket carries the compiled binary and k6 script.
4. **SQS:** one encrypted Standard queue with long polling, one-hour retention, and a two-minute visibility timeout.
5. **RDS:** private, encrypted, Single-AZ PostgreSQL. RDS creates and manages the master password in Secrets Manager.
6. **ALB:** internal HTTP only. It is reachable from the generator security group, not from the internet.
7. **IAM:** API can read its binary and publish; worker can read its binary, consume, and fetch only the database secret; generator can read the test script and course token.
8. **EC2:** IMDSv2 is mandatory, SSM replaces SSH, and systemd runs the binary.
9. **Auto Scaling groups:** fixed counts make the lesson deterministic; no reactive scaling is being tested.

## 18. Create the boot templates

Put this in `infra/app_user_data.sh.tftpl`:

```bash
#!/bin/bash
set -euo pipefail

dnf install -y awscli curl
install -d -m 0755 /opt/burstlab

for attempt in $(seq 1 30); do
  if aws s3 cp "s3://${bucket}/${artifact_key}" /usr/local/bin/burstlab --region "${region}"; then
    break
  fi
  sleep 5
done
chmod 0755 /usr/local/bin/burstlab
test -x /usr/local/bin/burstlab

%{ if role == "worker" ~}
curl -fsSLo /opt/burstlab/global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
%{ endif ~}

cat >/etc/burstlab.env <<'ENV'
AWS_REGION=${region}
BURSTLAB_MODE=${role}
QUEUE_URL=${queue_url}
TOKEN_SHA256=${token_hash}
DB_HOST=${db_host}
DB_NAME=burstlab
DB_SECRET_ARN=${db_secret_arn}
RDS_CA_FILE=/opt/burstlab/global-bundle.pem
ENV
chmod 0600 /etc/burstlab.env

cat >/etc/systemd/system/burstlab.service <<'UNIT'
[Unit]
Description=BurstLab course service
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/burstlab.env
ExecStart=/usr/local/bin/burstlab
Restart=always
RestartSec=2
User=nobody
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now burstlab
```

Put this in `infra/loadgen_user_data.sh.tftpl`:

```bash
#!/bin/bash
set -euo pipefail

dnf install -y awscli curl
dnf install -y https://dl.k6.io/rpm/repo.rpm
dnf install -y k6
install -d -m 0755 /opt/burstlab

for attempt in $(seq 1 30); do
  if aws s3 cp "s3://${bucket}/${load_key}" /opt/burstlab/load.js --region "${region}"; then
    break
  fi
  sleep 5
done
test -f /opt/burstlab/load.js
```

The worker downloads Amazon's RDS CA bundle and pgx uses `sslmode=verify-full`. The database password never appears in user data, Terraform variables, or the process command line.

## 19. Create `infra/outputs.tf`

```hcl
output "load_url" {
  value = "http://${aws_lb.api.dns_name}:8080"
}

output "queue_url" {
  value = aws_sqs_queue.events.url
}

output "region" {
  value = var.region
}

output "mode" {
  value = var.burst_mode ? "burst" : "learning"
}

output "loadgen_count" {
  value = local.loadgen_count
}

output "target_group_arn" {
  value = aws_lb_target_group.api.arn
}
```

## 20. Format and validate without creating anything

```bash
terraform -chdir=infra init
terraform -chdir=infra fmt -check
terraform -chdir=infra validate
```

Terraform generates `.terraform.lock.hcl`. Keep it with the course source so future runs use the provider selection you tested.

**Checkpoint:** validation says `Success! The configuration is valid.` No AWS infrastructure exists yet.

# Part VI - Create the learning deployment

## 21. Generate the course token safely

Generate 256 bits of randomness locally, store the plaintext in SSM Parameter Store, and give Terraform only its SHA-256 hash:

```bash
COURSE_TOKEN=$(openssl rand -hex 32)
TOKEN_SHA256=$(printf '%s' "$COURSE_TOKEN" | openssl dgst -sha256 | awk '{print $2}')

aws ssm put-parameter \
  --name /burstlab/course-token \
  --type SecureString \
  --value "$COURSE_TOKEN" \
  --overwrite

export TF_VAR_token_sha256="$TOKEN_SHA256"
export TF_VAR_expires_at="REPLACE-WITH-A-UTC-TIME-TWO-HOURS-FROM-NOW"
```

Do not paste the plaintext token into Terraform, Git, screenshots, or course notes. If you open another terminal, retrieve it without printing it:

```bash
COURSE_TOKEN=$(aws ssm get-parameter \
  --name /burstlab/course-token \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text)
```

## 22. Review the learning plan

```bash
terraform -chdir=infra plan -out=learning.tfplan
terraform -chdir=infra show learning.tfplan
```

Confirm the plan says learning mode and contains:

- one `t4g.micro` API;
- one `t4g.micro` worker;
- zero load generators;
- one `db.t4g.micro` database with 20 GiB;
- one internal ALB and one SQS queue;
- no NAT Gateway and no public database.

If the plan shows burst classes or unexpected resources, stop.

## 23. Apply the learning deployment

Start a two-hour timer, then apply the reviewed plan:

```bash
terraform -chdir=infra apply learning.tfplan
terraform -chdir=infra output
```

RDS creation is normally the slowest step. EC2 instances then download the application and register with Systems Manager.

Find the instances:

```bash
aws ec2 describe-instances \
  --filters 'Name=tag:Project,Values=burstlab-course' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Role`].Value|[0],InstanceType]' \
  --output table
```

**Checkpoint:** one API and one worker are running. The load-generator count is zero.

## 24. Inspect the API without opening a network port

Get the API instance ID:

```bash
API_ID=$(aws ec2 describe-instances \
  --filters 'Name=tag:Role,Values=api' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)
echo "$API_ID"
```

Open an SSM port-forwarding session:

```bash
aws ssm start-session \
  --target "$API_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["18080"]}'
```

Leave that terminal open. In a second terminal with `COURSE_TOKEN` loaded:

```bash
curl -i http://127.0.0.1:18080/health/ready

EVENT_TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
curl -i \
  -X POST http://127.0.0.1:18080/v1/events \
  -H "Authorization: Bearer $COURSE_TOKEN" \
  -H 'Content-Type: application/json' \
  --data "{\"request_id\":\"lesson-1\",\"event_ts\":\"$EVENT_TS\",\"value\":\"hello\"}"
```

Expected response: HTTP `202 Accepted`.

Try the same request with `Bearer wrong`. Expected response: `401 Unauthorized`. Try a second JSON object or a timestamp two days in the future. Expected response: `400 Bad Request`.

## 25. Prove that the worker committed the event

Find the worker and open an SSM shell:

```bash
WORKER_ID=$(aws ec2 describe-instances \
  --filters 'Name=tag:Role,Values=worker' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

aws ssm start-session --target "$WORKER_ID"
```

Inside the worker session:

```bash
sudo systemctl status burstlab --no-pager
sudo journalctl -u burstlab --since '10 minutes ago' --no-pager
sudo bash -lc 'set -a; source /etc/burstlab.env; BURSTLAB_MODE=count /usr/local/bin/burstlab'
exit
```

Expected count after a short wait:

```json
{"events":1,"quarantine":0}
```

Send `lesson-1` again with the same timestamp:

```bash
curl -i \
  -X POST http://127.0.0.1:18080/v1/events \
  -H "Authorization: Bearer $COURSE_TOKEN" \
  -H 'Content-Type: application/json' \
  --data "{\"request_id\":\"lesson-1\",\"event_ts\":\"$EVENT_TS\",\"value\":\"hello again\"}"
```

This deliberate duplicate simulates the database effect of an at-least-once redelivery. It receives `202`, but the database count remains one because `(tenant_id, request_id)` is the primary key. Reopen the worker session and rerun the count command to prove that claim; do not merely assume it.

## 26. Inspect the AWS services

Use the AWS console or CLI to answer these questions:

1. Which subnets contain the RDS instance?
2. Does RDS have a public endpoint?
3. Which security group can reach port 5432?
4. Which IAM actions can the API role perform on SQS?
5. What is the queue visibility timeout?
6. What happens to a message if the database transaction fails?
7. Why can the API return `202` while the database row appears later?

Do not continue until you can explain each answer.

## 27. Run a safe failure exercise

Reopen a Systems Manager session to the worker from your local terminal:

```bash
aws ssm start-session --target "$WORKER_ID"
```

Then stop the service inside that session:

```bash
sudo systemctl stop burstlab
exit
```

From your local terminal, send five new valid events through the still-open API port-forwarding session:

```bash
for N in 1 2 3 4 5; do
  EVENT_TS=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  curl --silent --output /dev/null --write-out "failure-$N: %{http_code}\n" \
    -X POST http://127.0.0.1:18080/v1/events \
    -H "Authorization: Bearer $COURSE_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "{\"request_id\":\"failure-$N\",\"event_ts\":\"$EVENT_TS\",\"value\":\"queued\"}"
done
```

Each status should be `202`. Inspect the queue:

```bash
QUEUE_URL=$(terraform -chdir=infra output -raw queue_url)
aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

Reopen the worker session, restart the service, and close the session:

```bash
aws ssm start-session --target "$WORKER_ID"
sudo systemctl start burstlab
exit
```

The messages should drain and appear in PostgreSQL. This demonstrates decoupling: a temporary database consumer outage did not force the API to write synchronously.

## 28. Destroy the learning deployment

End SSM sessions, then run:

```bash
terraform -chdir=infra plan -destroy -out=destroy-learning.tfplan
terraform -chdir=infra show destroy-learning.tfplan
terraform -chdir=infra apply destroy-learning.tfplan
```

Do not delete the `/burstlab/course-token` parameter yet if you will run the capstone.

Verify that Terraform manages nothing:

```bash
terraform -chdir=infra state list
```

Expected output: empty.

# Part VII - Optional 15K-RPS capstone

## 29. Capstone admission gate

Proceed only when all statements are true:

- the learning deployment worked and was destroyed;
- `go test`, `go vet`, `terraform fmt -check`, and `terraform validate` pass;
- the EC2 Standard On-Demand quota is at least 24 vCPUs;
- the account has no unrelated resources using that quota;
- a $10 notification and $20 stop condition exist;
- the current EC2 Testing Policy has been reviewed;
- you can supervise the entire run and teardown;
- the system contains synthetic data only.

If any statement is false, stop. The learner has already completed a real deployment; the capstone can wait.

## 30. Rebuild and plan burst mode

Rebuild so the uploaded binary exactly matches the tested source:

```bash
go test ./...
go vet ./...
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -trimpath -ldflags='-s -w' -o dist/burstlab ./app

export TF_VAR_expires_at="REPLACE-WITH-A-UTC-TIME-TWO-HOURS-FROM-NOW"
terraform -chdir=infra plan -var='burst_mode=true' -out=burst.tfplan
terraform -chdir=infra show burst.tfplan
```

Confirm exactly:

- 2 API `c7g.xlarge` instances;
- 2 worker `c7g.xlarge` instances;
- 2 load-generator `c7g.xlarge` instances;
- 1 Single-AZ `db.r7g.xlarge` with 400-GiB gp3;
- the same internal ALB and SQS shape;
- 24 total EC2 vCPUs.

Start a two-hour timer and apply:

```bash
terraform -chdir=infra apply burst.tfplan
```

## 31. Verify readiness before generating load

List the six EC2 instances:

```bash
aws ec2 describe-instances \
  --filters 'Name=tag:Project,Values=burstlab-course' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Role`].Value|[0],InstanceType]' \
  --output table
```

Verify the ALB targets:

```bash
TARGET_GROUP_ARN=$(terraform -chdir=infra output -raw target_group_arn)
aws elbv2 describe-target-health --target-group-arn "$TARGET_GROUP_ARN"
```

Both API targets must be `healthy`.

Verify that both generators are online in Systems Manager:

```bash
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].[InstanceId,PingStatus]' \
  --output table
```

Do not start the test while targets are unhealthy or generators are absent.

## 32. Create a reusable remote-run helper

The following shell function sends one command to every instance tagged `Role=loadgen` without putting the plaintext course token in the command or Terraform state:

```bash
run_load() {
  profile="$1"
  load_url=$(terraform -chdir=infra output -raw load_url)
  loadgens=$(terraform -chdir=infra output -raw loadgen_count)
  target_rps=$((15000 / loadgens))

  parameters=$(jq -nc \
    --arg url "$load_url" \
    --arg profile "$profile" \
    --arg rate "$target_rps" \
    '{commands:[
      "set -euo pipefail",
      "TOKEN=$(aws ssm get-parameter --name /burstlab/course-token --with-decryption --query Parameter.Value --output text)",
      "IMDS_TOKEN=$(curl -fsS -X PUT -H X-aws-ec2-metadata-token-ttl-seconds:21600 http://169.254.169.254/latest/api/token)",
      "GENERATOR_ID=$(curl -fsS -H X-aws-ec2-metadata-token:$IMDS_TOKEN http://169.254.169.254/latest/meta-data/instance-id)",
      ("k6 run --summary-export=/tmp/k6-"+$profile+".json -e URL="+$url+" -e TOKEN=$TOKEN -e GENERATOR_ID=$GENERATOR_ID -e TARGET_RPS="+$rate+" -e PROFILE="+$profile+" /opt/burstlab/load.js"),
      "unset TOKEN"
    ]}')

  aws ssm send-command \
    --document-name AWS-RunShellScript \
    --targets 'Key=tag:Role,Values=loadgen' \
    --parameters "$parameters" \
    --comment "burstlab-$profile"
}
```

This helper requires `jq`. If it is not installed, install it from your operating system's trusted package source.

`send-command` prints a command ID. Use it to inspect completion:

```bash
aws ssm list-command-invocations --command-id REPLACE_ME --details
```

## 33. Calibrate the generators

Run only the health endpoint first:

```bash
run_load calibrate
```

The two generators ramp to 7,500 RPS each and hold for one minute. This produces no SQS events.

Pass conditions:

- aggregate rate reaches approximately 15K RPS;
- `dropped_iterations` is zero;
- generator CPU stays below approximately 60%;
- ALB/API p95 is under the provisional threshold;
- both generators finish successfully.

If generators are the bottleneck, do not claim the application failed. Destroy and repeat another day with four generators:

```bash
terraform -chdir=infra plan \
  -var='burst_mode=true' \
  -var='burst_loadgen_count=4' \
  -out=four-generators.tfplan
```

That shape needs 32 Standard-family EC2 vCPUs. Do not resize during an active paid test.

## 34. Run the short burst test

Record UTC start time and current estimated spend. Then run:

```bash
run_load full
```

The full traffic window lasts 15 minutes:

1. Two minutes at 1,000 aggregate RPS.
2. Three-minute ramp from 1,000 to 15,000 RPS.
3. Ten minutes at 15,000 RPS.

Do not extend the hold because results look interesting. A longer test is a separate budget decision.

Stop conditions during the run:

- estimated spend reaches $10;
- generator dropped iterations appear;
- HTTP failures exceed 0.5% for two minutes;
- queue publish failures cause `503` responses;
- database or queue errors grow continuously;
- you lose the ability to supervise teardown.

Stopping early is a valid test result.

## 35. Observe without expensive per-request logs

Watch these native AWS metrics in CloudWatch:

| Service | Metrics |
| --- | --- |
| ALB | RequestCount, TargetResponseTime, HTTPCode_Target_5XX_Count, HealthyHostCount, ConsumedLCUs |
| EC2/ASG | CPUUtilization, instance count, status checks |
| SQS | NumberOfMessagesSent, NumberOfMessagesReceived, ApproximateNumberOfMessagesVisible, ApproximateAgeOfOldestMessage |
| RDS | CPUUtilization, DatabaseConnections, WriteIOPS, WriteThroughput, WriteLatency, FreeStorageSpace |

Inspect aggregate application logs over SSM if needed:

```bash
aws ssm start-session --target REPLACE_WITH_ONE_API_OR_WORKER_ID
sudo journalctl -u burstlab --since '30 minutes ago' --no-pager | tail -100
```

Do not turn on one log line per event. At millions of requests, logging can distort both performance and cost.

## 36. Drain and reconcile

When k6 finishes, stop generating traffic but keep the workers and database running for at most 30 minutes.

Check the queue every minute:

```bash
QUEUE_URL=$(terraform -chdir=infra output -raw queue_url)
aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names \
    ApproximateNumberOfMessages \
    ApproximateNumberOfMessagesNotVisible \
    ApproximateAgeOfOldestMessage
```

Query database counts from a worker with the same SSM procedure used in Lesson 25:

```bash
sudo bash -lc 'set -a; source /etc/burstlab.env; BURSTLAB_MODE=count /usr/local/bin/burstlab'
```

Collect each generator's k6 summary with Run Command or an SSM session. Add the `202`/accepted totals from both generators.

Pass conditions for this first test:

- aggregate load reached 15K RPS;
- the 10-minute hold completed or a clear stop condition was recorded;
- dropped iterations are zero;
- failed request rate is below 0.5%;
- p95 is below the provisional 150-ms target;
- database event count matches accepted unique request IDs after drain;
- quarantine is zero;
- the queue returns to zero visible and zero in-flight messages;
- there is no unexplained accepted-event loss;
- observed SQS batches are near ten at peak;
- the environment remains below the $20 ceiling.

If the queue has not drained after 30 minutes, record the backlog, oldest age, worker/database metrics, and mark the worker test failed. Do not keep paying indefinitely merely to reach zero.

## 37. Interpret the result honestly

A pass proves:

> This exact code and AWS shape accepted approximately 15K RPS for ten minutes, with the observed latency/error rate, and drained the generated backlog under the test conditions.

It does not prove:

- a one-hour or multi-day workload;
- behavior with seven days of existing database data;
- Internet-client latency or public TLS capacity;
- Availability Zone or Region failure survival;
- correctness for other schemas, payload sizes, authentication systems, or query loads;
- future AWS capacity or price;
- production readiness.

The wording of a performance result is part of engineering ethics. Never turn a ten-minute observation into an unlimited capacity promise.

## 38. Destroy immediately

After capturing the summaries:

```bash
terraform -chdir=infra plan \
  -destroy \
  -var='burst_mode=true' \
  -out=destroy-burst.tfplan
terraform -chdir=infra show destroy-burst.tfplan
terraform -chdir=infra apply destroy-burst.tfplan
```

If you used four generators, pass `-var='burst_loadgen_count=4'` to the destroy plan too.

Delete the manually created token:

```bash
aws ssm delete-parameter --name /burstlab/course-token
unset COURSE_TOKEN TOKEN_SHA256 TF_VAR_token_sha256 TF_VAR_expires_at
```

Verify:

```bash
terraform -chdir=infra state list

aws rds describe-db-instances \
  --query 'DBInstances[?starts_with(DBInstanceIdentifier, `burstlab`)].DBInstanceIdentifier'

aws ec2 describe-instances \
  --filters 'Name=tag:Project,Values=burstlab-course' 'Name=instance-state-name,Values=pending,running,stopping,stopped' \
  --query 'Reservations[].Instances[].InstanceId'
```

All three outputs should be empty. Check S3, ALB, SQS, Secrets Manager, and the next day's Cost Explorer as a final audit.

Stopping an RDS instance is not cleanup: storage and backup charges continue. This course deletes the instance and takes no final snapshot because all data is synthetic.

# Part VIII - Security walkthrough

## 39. Trust boundaries

| Boundary | Lab control | What it prevents |
| --- | --- | --- |
| Human to AWS | SSO/temporary role and MFA | Long-lived root or IAM access keys |
| Generator to ALB | Internal ALB plus security-group source | Public access to the test endpoint |
| Request to API | Bearer-token hash, constant-time comparison, 1-KiB limit, strict JSON | Casual unauthorized or oversized input |
| API to SQS | Instance role restricted to one queue | Database credentials on API nodes |
| Worker to SQS | Separate receive/delete role | API deleting queued work |
| Worker to RDS | Private endpoint, worker-only security group, TLS verification | Public database access and unverified TLS |
| Artefact delivery | Private encrypted S3, role-scoped read | Public binary/script download |
| Administration | SSM and IMDSv2; no SSH rule | Public administrative port and static SSH keys |

## 40. Secrets

The plaintext course token is stored as an SSM `SecureString`. API nodes receive only its SHA-256 digest. Load generators may decrypt the one named parameter; API and worker roles may not.

RDS generates its master password in Secrets Manager. Terraform sees the secret ARN, not the password. Workers fetch the password using their instance role.

The worker using a database master credential is an educational shortcut. Production should create a dedicated migration role and a lower-privilege writer role. The token hash is also not a full authentication platform: production would normally validate short-lived asymmetric tokens and tenant claims.

## 41. Encryption

- SQS uses server-side encryption managed by SQS.
- RDS storage and S3 artefacts are encrypted at rest.
- PostgreSQL uses `verify-full` with the AWS RDS CA bundle.
- The human-to-instance administrative path uses Systems Manager.
- The ALB-to-generator test path is HTTP inside a restricted VPC security-group boundary.

That final point is a deliberate lab limit. A public deployment needs a domain, ACM certificate, HTTPS listener, TLS policy, public-entry threat model, abuse controls, and usually a separate cost discussion. Do not make this ALB public and call it secure.

## 42. Data and logs

Use synthetic events only. The application never logs payloads or tokens. It logs aggregate counters and batch errors. The quarantine table stores malformed queue payloads, so its data must be treated as sensitive in a real system.

The lab disables backups and destroys data. Production requires retention, deletion, backup, restore, and legal decisions before schema design is final.

## 43. Security exercises

Try these only against your course deployment:

1. Send no token: expect `401` and no queue message.
2. Send an unknown JSON field: expect `400`.
3. Send a body over 1 KiB: expect rejection.
4. Send an event timestamp 25 hours ahead: expect `400`.
5. Attempt to connect to RDS from your laptop: it should be unreachable.
6. Inspect the API IAM policy: it must not contain `sqs:ReceiveMessage` or `secretsmanager:GetSecretValue`.
7. Inspect the worker security group: it has no ingress rule.
8. Confirm EC2 metadata options require IMDSv2.

# Part IX - Troubleshooting

## 44. Terraform says the binary does not exist

Run the ARM64 build command first. Terraform uploads `dist/burstlab` and hashes it during planning.

## 45. RDS class or Graviton instances are unavailable

Confirm the Region is `ap-south-1` and inspect current regional availability. Do not silently substitute a smaller database and compare its result with the course target. A substitute is a new experiment.

## 46. Instances do not appear in Systems Manager

Check:

- the instance has a public IP and public route for outbound access;
- `AmazonSSMManagedInstanceCore` is attached;
- the SSM agent is running in the Amazon Linux 2023 AMI;
- the instance role was attached;
- user-data logs in `/var/log/cloud-init-output.log`.

Use the EC2 serial console only if it is already configured; do not add an Internet-wide SSH rule as a shortcut.

## 47. ALB targets are unhealthy

Open an SSM session on an API and run:

```bash
sudo systemctl status burstlab --no-pager
sudo journalctl -u burstlab --since '15 minutes ago' --no-pager
curl -i http://127.0.0.1:8080/health/ready
```

Common causes are an incomplete S3 download, SQS IAM propagation, wrong Region, or application startup failure.

## 48. Worker cannot connect to PostgreSQL

Check the worker journal, RDS status, worker-to-database security-group rule, secret permission, DB endpoint, and CA file. Do not set `sslmode=disable` to make the error disappear.

## 49. k6 reports dropped iterations

First decide whether the generator or target is constrained:

- generator CPU/memory high: add generators and divide 15K by the new count;
- generator healthy but ALB/API latency rises: target is constrained;
- API healthy but SQS publish latency rises: producer/AWS-service path is constrained;
- API succeeds but queue age grows: workers/database are constrained.

Dropped iterations mean the requested arrival rate was not actually produced. Do not report the configured rate as achieved.

## 50. Terraform destroy fails

Read the exact dependency error. Retry after AWS finishes deleting dependent resources. Check for a manually created final RDS snapshot, object in the artefact bucket, or resource created outside Terraform. Do not delete the Terraform state file to hide live resources.

# Part X - Instructor material

## 51. Demonstration checkpoints

| Checkpoint | Learner evidence |
| --- | --- |
| Local correctness | `go test` and `go vet` pass |
| IaC correctness | `terraform fmt -check` and `validate` pass |
| Auth boundary | correct token gets `202`; wrong token gets `401` |
| Durable acceptance | SQS failure cannot produce `202` |
| Eventual processing | worker count shows the accepted row |
| Idempotency | redelivery leaves one database row |
| Decoupling | stopped worker creates queue backlog; restart drains it |
| Network security | no public ALB/database/application ingress |
| Generator validity | 15K calibration with zero dropped iterations |
| Short load | ten-minute 15K hold or documented stop condition |
| Data integrity | accepted unique IDs reconcile with database plus queue/quarantine |
| Cost safety | actual cost below $20 and all resources destroyed |

## 52. Discussion prompts

1. Why is returning `202` before SQS acknowledgement a data-loss bug?
2. Why does `COPY` directly into a uniquely indexed table make redelivery awkward?
3. Why can a queue grow during a healthy burst?
4. Why does request-rate testing need an open load model?
5. Why is the load generator itself part of the measurement system?
6. Which lab shortcuts are unacceptable for personal data?
7. What changes if clients do not reuse HTTP connections?
8. What can a ten-minute test establish, and what remains unknown?
9. Why is a budget alert weaker than immediate teardown?
10. Why should production use a dedicated database writer credential?

## 53. Optional extensions after the core course

Add one extension at a time and remeasure:

- create a non-master PostgreSQL migration and writer role;
- publish application metrics to CloudWatch once every ten seconds;
- add a deliberately duplicated event percentage to k6;
- stop one API during load and observe target health;
- add a real domain and ACM certificate to a separate public-entry lesson;
- compare two versus four load generators;
- preload older data and measure index/storage effects;
- add seven-day backups and perform a restore in a separate costed lesson.

Do not add Kubernetes, Kafka, Redis, sharding, multi-region failover, or a custom observability platform merely to make the diagram larger. Each deserves its own requirement and course.

## 54. Glossary

| Term | Meaning here |
| --- | --- |
| ALB | Application Load Balancer; routes HTTP requests to healthy APIs |
| ASG | Auto Scaling group; maintains a requested EC2 instance count |
| At least once | A message may be delivered more than once but should not be lost after acceptance |
| Backlog | Accepted queue messages not yet fully processed |
| Batch | Several events handled in one network/database operation |
| DRI | The one person responsible for moving an item to completion |
| Idempotency | Repeating the same logical event leaves the same stored result |
| IMDSv2 | Token-protected EC2 instance metadata protocol |
| LCU | ALB capacity/billing unit based on connections, bytes, and rules |
| Long polling | Waiting for SQS messages instead of repeatedly receiving empty results |
| p95 | 95% of measured requests were at or below this latency |
| RPS | Requests per second |
| SLO | A measurable service objective for latency, errors, or availability |
| Visibility timeout | Time during which a received SQS message is hidden before redelivery |

## 55. Authoritative references

- AWS IAM security controls: <https://docs.aws.amazon.com/prescriptive-guidance/latest/security-controls-by-caf-capability/identity-and-access-controls.html>
- AWS IAM best practices: <https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html>
- Systems Manager instance permissions: <https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-instance-permissions.html>
- Amazon EC2 Testing Policy: <https://aws.amazon.com/ec2/testing/>
- SQS batching and horizontal scaling: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-throughput-horizontal-scaling-and-batching.html>
- SQS long polling: <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-short-and-long-polling.html>
- SQS pricing: <https://aws.amazon.com/sqs/pricing/>
- RDS-managed master passwords: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html>
- RDS billing: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/User_DBInstanceBilling.html>
- RDS gp3 storage behavior: <https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_Storage.html>
- Terraform AWS tutorials: <https://developer.hashicorp.com/terraform/tutorials/aws-get-started>
- Terraform AWS provider: <https://registry.terraform.io/providers/hashicorp/aws/latest/docs>
- Go getting started: <https://go.dev/doc/tutorial/getting-started>
- k6 installation: <https://grafana.com/docs/k6/latest/set-up/install-k6/>
- k6 arrival-rate model: <https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/constant-arrival-rate/>

## Final rule

The course is complete only when the learner can show both results:

```text
The event path worked.
The AWS resources are gone.
```
