package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nats-io/nats.go"
)

const (
	streamName            = "EVENTS"
	eventSubject          = "events.ingest"
	consumerName          = "burstlab-worker"
	tenantID              = "course-tenant"
	batchSize             = 1000
	batchWindow           = 50 * time.Millisecond
	maxStreamBytes  int64 = 8 << 30
	duplicateWindow       = 2 * time.Minute
	consumerAckWait       = 2 * time.Minute
	maxAckPending         = 20_000
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

type badEnvelope struct {
	streamSequence int64
	payload        []byte
	reason         string
}

type stats struct {
	accepted   atomic.Uint64
	rejected   atomic.Uint64
	committed  atomic.Uint64
	duplicates atomic.Uint64
	quarantine atomic.Uint64
	acked      atomic.Uint64
	errors     atomic.Uint64
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var err error
	switch os.Getenv("BURSTLAB_MODE") {
	case "api":
		err = runAPI(ctx)
	case "worker":
		err = runWorker(ctx)
	case "count":
		err = printCounts(ctx)
	default:
		err = errors.New("BURSTLAB_MODE must be api, worker, or count")
	}
	if err != nil && !errors.Is(err, context.Canceled) {
		log.Fatal(err)
	}
}

func runAPI(ctx context.Context) error {
	expectedToken, err := tokenHash(os.Getenv("TOKEN_SHA256"))
	if err != nil {
		return err
	}
	nc, js, err := connectJetStream("api")
	if err != nil {
		return err
	}
	defer nc.Close()

	s := &stats{}
	go logStats(ctx, s)
	publish := func(ctx context.Context, body []byte) error {
		publishCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		_, err := js.Publish(eventSubject, body, nats.Context(publishCtx))
		return err
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health/live", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/health/ready", func(w http.ResponseWriter, _ *http.Request) {
		if !nc.IsConnected() {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/stats", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(statsSnapshot(s))
	})
	mux.Handle("/v1/events", eventHandler(expectedToken, publish, s))

	server := &http.Server{
		Addr:              env("HTTP_ADDR", "127.0.0.1:8080"),
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
		ReadTimeout:       3 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("api listening on %s", server.Addr)
	serveErr := make(chan error, 1)
	go func() { serveErr <- server.ListenAndServe() }()
	select {
	case err = <-serveErr:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		shutdownErr := server.Shutdown(shutdownCtx)
		cancel()
		err = <-serveErr
		if shutdownErr != nil {
			return fmt.Errorf("shut down API: %w", shutdownErr)
		}
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}

func eventHandler(expectedToken []byte, publish func(context.Context, []byte) error, s *stats) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !authorized(r.Header.Get("Authorization"), expectedToken) {
			s.rejected.Add(1)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		input, err := decodeEvent(r.Body)
		if err != nil {
			s.rejected.Add(1)
			http.Error(w, "invalid JSON", http.StatusBadRequest)
			return
		}
		if err := validateEvent(input, time.Now()); err != nil {
			s.rejected.Add(1)
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		body, err := json.Marshal(envelope{
			TenantID: tenantID, RequestID: input.RequestID, EventTS: input.EventTS, Value: input.Value,
		})
		if err != nil {
			s.errors.Add(1)
			http.Error(w, "encode event", http.StatusInternalServerError)
			return
		}
		if err := publish(r.Context(), body); err != nil {
			s.errors.Add(1)
			w.Header().Set("Retry-After", "1")
			http.Error(w, "queue unavailable", http.StatusServiceUnavailable)
			return
		}
		s.accepted.Add(1)
		w.WriteHeader(http.StatusAccepted)
	})
}

func runWorker(ctx context.Context) error {
	databaseURL, err := requiredEnv("DATABASE_URL")
	if err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, databaseURL)
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

	nc, js, err := connectJetStream("worker")
	if err != nil {
		return err
	}
	defer nc.Close()
	sub, err := js.PullSubscribe(eventSubject, consumerName,
		nats.BindStream(streamName), nats.ManualAck(), nats.AckExplicit(),
		nats.DeliverAll(), nats.ReplayInstant(), nats.AckWait(consumerAckWait),
		nats.MaxDeliver(-1), nats.MaxAckPending(maxAckPending))
	if err != nil {
		return fmt.Errorf("create consumer: %w", err)
	}
	consumerInfo, err := js.ConsumerInfo(streamName, consumerName)
	if err != nil {
		return fmt.Errorf("inspect consumer: %w", err)
	}
	if err := validateConsumer(consumerInfo); err != nil {
		return err
	}

	s := &stats{}
	go logStats(ctx, s)
	log.Printf("worker started")
	for ctx.Err() == nil {
		messages, fetchErr := sub.Fetch(batchSize, nats.MaxWait(batchWindow))
		if len(messages) == 0 {
			if fetchErr != nil && !errors.Is(fetchErr, nats.ErrTimeout) {
				s.errors.Add(1)
				time.Sleep(100 * time.Millisecond)
			}
			continue
		}
		if err := writeBatch(ctx, pool, messages, s); err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			s.errors.Add(1)
			log.Printf("database batch failed: %v", err)
			continue
		}
		acked := 0
		for _, message := range messages {
			if err := message.Ack(); err != nil {
				s.errors.Add(1)
				continue
			}
			acked++
		}
		if acked > 0 {
			if err := nc.FlushTimeout(2 * time.Second); err != nil {
				s.errors.Add(1)
			} else {
				s.acked.Add(uint64(acked))
			}
		}
	}
	return ctx.Err()
}

func writeBatch(ctx context.Context, pool *pgxpool.Pool, messages []*nats.Msg, s *stats) error {
	valid, bad, err := splitEnvelopes(messages)
	if err != nil {
		return err
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var inserted int64
	if len(valid) > 0 {
		if _, err = tx.Exec(ctx, `CREATE TEMP TABLE IF NOT EXISTS stage_events
			(tenant_id text, request_id text, event_ts timestamptz, value text) ON COMMIT DELETE ROWS`); err != nil {
			return err
		}
		rows := make([][]any, len(valid))
		for i, item := range valid {
			rows[i] = []any{item.TenantID, item.RequestID, item.EventTS, item.Value}
		}
		if _, err = tx.CopyFrom(ctx, pgx.Identifier{"stage_events"},
			[]string{"tenant_id", "request_id", "event_ts", "value"}, pgx.CopyFromRows(rows)); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `INSERT INTO events (tenant_id, request_id, event_ts, value)
			SELECT tenant_id, request_id, event_ts, value FROM stage_events
			ON CONFLICT (tenant_id, request_id) DO NOTHING`)
		if err != nil {
			return err
		}
		inserted = tag.RowsAffected()
	}
	var quarantined int64
	if len(bad) > 0 {
		if _, err = tx.Exec(ctx, `CREATE TEMP TABLE IF NOT EXISTS stage_quarantine
			(stream_sequence bigint, payload bytea, reason text) ON COMMIT DELETE ROWS`); err != nil {
			return err
		}
		rows := make([][]any, len(bad))
		for i, item := range bad {
			rows[i] = []any{item.streamSequence, item.payload, item.reason}
		}
		if _, err = tx.CopyFrom(ctx, pgx.Identifier{"stage_quarantine"},
			[]string{"stream_sequence", "payload", "reason"}, pgx.CopyFromRows(rows)); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `INSERT INTO quarantine (stream_sequence, payload, reason)
			SELECT stream_sequence, payload, reason FROM stage_quarantine
			ON CONFLICT (stream_sequence) DO NOTHING`)
		if err != nil {
			return err
		}
		quarantined = tag.RowsAffected()
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	s.committed.Add(uint64(inserted))
	s.duplicates.Add(uint64(len(valid)) - uint64(inserted))
	s.quarantine.Add(uint64(quarantined))
	return nil
}

func splitEnvelopes(messages []*nats.Msg) ([]envelope, []badEnvelope, error) {
	valid := make([]envelope, 0, len(messages))
	bad := make([]badEnvelope, 0)
	for _, message := range messages {
		item, err := parseEnvelope(message.Data)
		if err != nil {
			metadata, metadataErr := message.Metadata()
			if metadataErr != nil {
				return nil, nil, fmt.Errorf("read JetStream metadata on malformed message: %w", metadataErr)
			}
			if metadata.Sequence.Stream > uint64(^uint64(0)>>1) {
				return nil, nil, errors.New("JetStream sequence is too large for quarantine")
			}
			bad = append(bad, badEnvelope{
				streamSequence: int64(metadata.Sequence.Stream),
				payload:        append([]byte(nil), message.Data...),
				reason:         err.Error(),
			})
			continue
		}
		valid = append(valid, item)
	}
	return valid, bad, nil
}

func parseEnvelope(body []byte) (envelope, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	var item envelope
	if err := dec.Decode(&item); err != nil {
		return envelope{}, fmt.Errorf("invalid queue envelope: %w", err)
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return envelope{}, errors.New("invalid queue envelope: one JSON object required")
	}
	if item.TenantID != tenantID {
		return envelope{}, errors.New("invalid queue envelope: unknown tenant_id")
	}
	if err := validateRequestID(item.RequestID); err != nil {
		return envelope{}, fmt.Errorf("invalid queue envelope: %w", err)
	}
	if item.EventTS.IsZero() {
		return envelope{}, errors.New("invalid queue envelope: event_ts is required")
	}
	if err := validateValue(item.Value); err != nil {
		return envelope{}, fmt.Errorf("invalid queue envelope: %w", err)
	}
	return item, nil
}

func migrate(ctx context.Context, pool *pgxpool.Pool) error {
	_, err := pool.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS events (
			tenant_id text NOT NULL,
			request_id text NOT NULL,
			event_ts timestamptz NOT NULL,
			value text NOT NULL,
			accepted_at timestamptz NOT NULL DEFAULT now(),
			PRIMARY KEY (tenant_id, request_id)
		);
		CREATE TABLE IF NOT EXISTS quarantine (
			id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
			stream_sequence bigint NOT NULL,
			payload bytea NOT NULL,
			reason text NOT NULL,
			created_at timestamptz NOT NULL DEFAULT now()
		);
		ALTER TABLE quarantine ADD COLUMN IF NOT EXISTS stream_sequence bigint;
		CREATE UNIQUE INDEX IF NOT EXISTS quarantine_stream_sequence_idx
			ON quarantine (stream_sequence);`)
	if err != nil {
		return fmt.Errorf("migrate database: %w", err)
	}
	return nil
}

func printCounts(ctx context.Context) error {
	databaseURL, err := requiredEnv("DATABASE_URL")
	if err != nil {
		return err
	}
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := migrate(ctx, pool); err != nil {
		return err
	}
	var counts struct {
		RunID       string `json:"run_id,omitempty"`
		Events      int64  `json:"events"`
		TotalEvents int64  `json:"total_events"`
		Quarantine  int64  `json:"quarantine"`
	}
	counts.RunID = os.Getenv("RUN_ID")
	if err := pool.QueryRow(ctx, `SELECT
		count(*) FILTER (WHERE $1 = '' OR left(request_id, length($1) + 1) = $1 || '-'),
		count(*)
		FROM events`, counts.RunID).Scan(&counts.Events, &counts.TotalEvents); err != nil {
		return err
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM quarantine`).Scan(&counts.Quarantine); err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(counts)
}

func connectJetStream(name string) (*nats.Conn, nats.JetStreamContext, error) {
	nc, err := nats.Connect(env("NATS_URL", nats.DefaultURL), nats.Name("burstlab-"+name), nats.Timeout(2*time.Second))
	if err != nil {
		return nil, nil, fmt.Errorf("connect to NATS: %w", err)
	}
	js, err := nc.JetStream()
	if err != nil {
		nc.Close()
		return nil, nil, fmt.Errorf("open JetStream: %w", err)
	}
	if err := ensureStream(js); err != nil {
		nc.Close()
		return nil, nil, err
	}
	return nc, js, nil
}

func ensureStream(js nats.JetStreamContext) error {
	info, err := js.StreamInfo(streamName)
	if err == nil {
		return validateStream(info)
	}
	if !errors.Is(err, nats.ErrStreamNotFound) {
		return fmt.Errorf("inspect JetStream stream: %w", err)
	}
	info, err = js.AddStream(&nats.StreamConfig{
		Name: streamName, Subjects: []string{eventSubject}, Storage: nats.FileStorage,
		Retention: nats.WorkQueuePolicy, Replicas: 1, MaxConsumers: -1, MaxMsgs: -1,
		MaxBytes: maxStreamBytes, MaxAge: 0, MaxMsgsPerSubject: -1, MaxMsgSize: -1,
		Discard: nats.DiscardNew, Duplicates: duplicateWindow,
	})
	if err != nil {
		// The API and worker can race while creating the same stream.
		if info, err = js.StreamInfo(streamName); err != nil {
			return fmt.Errorf("create JetStream stream: %w", err)
		}
	}
	return validateStream(info)
}

func validateStream(info *nats.StreamInfo) error {
	config := info.Config
	if config.Storage != nats.FileStorage || config.Retention != nats.WorkQueuePolicy || config.Replicas != 1 ||
		config.MaxConsumers != -1 || config.MaxMsgs != -1 || config.MaxBytes != maxStreamBytes ||
		config.MaxAge != 0 || config.MaxMsgsPerSubject != -1 || config.MaxMsgSize != -1 ||
		config.Discard != nats.DiscardNew || config.DiscardNewPerSubject || config.NoAck ||
		config.Duplicates != duplicateWindow || config.Mirror != nil || len(config.Sources) != 0 ||
		len(config.Subjects) != 1 || config.Subjects[0] != eventSubject {
		return errors.New("EVENTS stream configuration does not match the benchmark contract")
	}
	return nil
}

func validateConsumer(info *nats.ConsumerInfo) error {
	config := info.Config
	if info.Stream != streamName || info.Name != consumerName || config.Durable != consumerName ||
		config.DeliverPolicy != nats.DeliverAllPolicy || config.AckPolicy != nats.AckExplicitPolicy ||
		config.AckWait != consumerAckWait || config.MaxDeliver != -1 ||
		config.FilterSubject != eventSubject || len(config.FilterSubjects) != 0 ||
		config.ReplayPolicy != nats.ReplayInstantPolicy || config.MaxAckPending != maxAckPending ||
		config.OptStartSeq != 0 || config.OptStartTime != nil || config.InactiveThreshold != 0 ||
		config.DeliverSubject != "" || config.DeliverGroup != "" || config.HeadersOnly || config.MemoryStorage {
		return errors.New("burstlab-worker consumer configuration does not match the benchmark contract")
	}
	return nil
}

func decodeEvent(body io.Reader) (event, error) {
	dec := json.NewDecoder(body)
	dec.DisallowUnknownFields()
	var input event
	if err := dec.Decode(&input); err != nil {
		return event{}, err
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		return event{}, errors.New("one JSON object required")
	}
	return input, nil
}

func tokenHash(value string) ([]byte, error) {
	expected, err := hex.DecodeString(value)
	if err != nil || len(expected) != sha256.Size {
		return nil, errors.New("TOKEN_SHA256 must be a 64-character SHA-256 hex digest")
	}
	return expected, nil
}

func authorized(header string, expected []byte) bool {
	token, ok := strings.CutPrefix(header, "Bearer ")
	if !ok || len(expected) != sha256.Size {
		return false
	}
	actual := sha256.Sum256([]byte(token))
	return subtle.ConstantTimeCompare(actual[:], expected) == 1
}

func validateEvent(input event, now time.Time) error {
	if err := validateRequestID(input.RequestID); err != nil {
		return err
	}
	if input.EventTS.Before(now.Add(-24*time.Hour)) || input.EventTS.After(now.Add(24*time.Hour)) {
		return errors.New("event_ts must be within 24 hours")
	}
	return validateValue(input.Value)
}

func validateValue(value string) error {
	if len(value) > 256 {
		return errors.New("value is longer than 256 bytes")
	}
	if strings.IndexByte(value, 0) >= 0 {
		return errors.New("value contains a NUL byte")
	}
	return nil
}

func validateRequestID(value string) error {
	if len(value) < 1 || len(value) > 64 {
		return errors.New("request_id must contain 1-64 characters")
	}
	for _, char := range value {
		if !(char == '-' || char == '_' || char >= '0' && char <= '9' || char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z') {
			return errors.New("request_id contains an unsupported character")
		}
	}
	return nil
}

func statsSnapshot(s *stats) map[string]uint64 {
	return map[string]uint64{
		"accepted": s.accepted.Load(), "rejected": s.rejected.Load(),
		"committed": s.committed.Load(), "duplicates": s.duplicates.Load(),
		"quarantine": s.quarantine.Load(), "acked": s.acked.Load(), "errors": s.errors.Load(),
	}
}

func logStats(ctx context.Context, s *stats) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			log.Printf("stats accepted=%d rejected=%d committed=%d duplicates=%d quarantine=%d acked=%d errors=%d",
				s.accepted.Load(), s.rejected.Load(), s.committed.Load(), s.duplicates.Load(),
				s.quarantine.Load(), s.acked.Load(), s.errors.Load())
		case <-ctx.Done():
			return
		}
	}
}

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func requiredEnv(name string) (string, error) {
	value := os.Getenv(name)
	if value == "" {
		return "", fmt.Errorf("%s is required", name)
	}
	return value, nil
}
