package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
)

func TestAuthorization(t *testing.T) {
	digest := sha256.Sum256([]byte("course-token"))
	expected, err := tokenHash(hex.EncodeToString(digest[:]))
	if err != nil {
		t.Fatal(err)
	}
	if !authorized("Bearer course-token", expected) {
		t.Fatal("correct token was rejected")
	}
	for _, header := range []string{"course-token", "Bearer wrong", "bearer course-token", "Bearer "} {
		if authorized(header, expected) {
			t.Fatalf("invalid authorization passed: %q", header)
		}
	}
	if _, err := tokenHash("not-a-digest"); err == nil {
		t.Fatal("invalid token digest passed")
	}
}

func TestValidateEvent(t *testing.T) {
	now := time.Date(2026, 8, 21, 12, 0, 0, 0, time.UTC)
	valid := event{RequestID: "event_1", EventTS: now, Value: "ok"}
	if err := validateEvent(valid, now); err != nil {
		t.Fatalf("valid event failed: %v", err)
	}
	tests := []struct {
		name  string
		event event
	}{
		{"empty request ID", event{EventTS: now}},
		{"invalid request ID", event{RequestID: "bad id", EventTS: now}},
		{"old timestamp", event{RequestID: "event-1", EventTS: now.Add(-25 * time.Hour)}},
		{"future timestamp", event{RequestID: "event-1", EventTS: now.Add(25 * time.Hour)}},
		{"long value", event{RequestID: "event-1", EventTS: now, Value: strings.Repeat("x", 257)}},
		{"NUL value", event{RequestID: "event-1", EventTS: now, Value: "bad\x00value"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if err := validateEvent(test.event, now); err == nil {
				t.Fatal("invalid event passed")
			}
		})
	}
}

func TestEventHandlerRejectsNonStrictOrOversizedJSON(t *testing.T) {
	digest := sha256.Sum256([]byte("course-token"))
	published := 0
	handler := eventHandler(digest[:], func(context.Context, []byte) error {
		published++
		return nil
	}, &stats{})
	timestamp := "2026-08-21T12:00:00Z"
	tests := []string{
		fmt.Sprintf(`{"request_id":"one","event_ts":%q,"value":"ok","extra":true}`, timestamp),
		fmt.Sprintf(`{"request_id":"one","event_ts":%q,"value":"ok"}{}`, timestamp),
		fmt.Sprintf(`{"request_id":"one","event_ts":%q,"value":"ok"}%s`, timestamp, strings.Repeat(" ", 1024)),
	}
	for _, body := range tests {
		req := httptest.NewRequest(http.MethodPost, "/v1/events", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer course-token")
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, req)
		if response.Code != http.StatusBadRequest {
			t.Fatalf("status = %d for %q", response.Code, body[:min(len(body), 100)])
		}
	}
	if published != 0 {
		t.Fatalf("published %d rejected events", published)
	}
}

func TestEventHandlerRequiresPublishAck(t *testing.T) {
	digest := sha256.Sum256([]byte("course-token"))
	body := fmt.Sprintf(`{"request_id":"one","event_ts":%q,"value":"ok"}`, time.Now().UTC().Format(time.RFC3339Nano))
	request := func() *http.Request {
		req := httptest.NewRequest(http.MethodPost, "/v1/events", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer course-token")
		return req
	}

	failed := eventHandler(digest[:], func(context.Context, []byte) error {
		return errors.New("no publish acknowledgement")
	}, &stats{})
	response := httptest.NewRecorder()
	failed.ServeHTTP(response, request())
	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status without publish acknowledgement = %d", response.Code)
	}

	succeeded := eventHandler(digest[:], func(context.Context, []byte) error { return nil }, &stats{})
	response = httptest.NewRecorder()
	succeeded.ServeHTTP(response, request())
	if response.Code != http.StatusAccepted {
		t.Fatalf("status with publish acknowledgement = %d", response.Code)
	}
}

func TestSplitEnvelopes(t *testing.T) {
	valid := fmt.Sprintf(`{"tenant_id":"%s","request_id":"one","event_ts":"2026-08-21T12:00:00Z","value":"ok"}`, tenantID)
	messages := []*nats.Msg{
		{Data: []byte(valid)},
		jetStreamMessage(2, `{"tenant_id":"course-tenant","request_id":"bad id","event_ts":"2026-08-21T12:00:00Z","value":"no"}`),
		jetStreamMessage(3, `not-json`),
		jetStreamMessage(4, `{"tenant_id":"course-tenant","request_id":"nul","event_ts":"2026-08-21T12:00:00Z","value":"\u0000"}`),
	}
	good, bad, err := splitEnvelopes(messages)
	if err != nil {
		t.Fatal(err)
	}
	if len(good) != 1 || good[0].RequestID != "one" {
		t.Fatalf("valid envelopes = %#v", good)
	}
	if len(bad) != 3 {
		t.Fatalf("bad envelope count = %d", len(bad))
	}
	if string(bad[1].payload) != "not-json" {
		t.Fatalf("quarantine payload = %q", bad[1].payload)
	}
	if bad[1].streamSequence != 3 {
		t.Fatalf("quarantine stream sequence = %d", bad[1].streamSequence)
	}
}

func TestValidateJetStreamContract(t *testing.T) {
	stream := &nats.StreamInfo{Config: nats.StreamConfig{
		Name: streamName, Subjects: []string{eventSubject}, Storage: nats.FileStorage,
		Retention: nats.WorkQueuePolicy, Replicas: 1, MaxConsumers: -1, MaxMsgs: -1,
		MaxBytes: maxStreamBytes, MaxMsgsPerSubject: -1, MaxMsgSize: -1,
		Discard: nats.DiscardNew, Duplicates: duplicateWindow,
	}}
	if err := validateStream(stream); err != nil {
		t.Fatalf("valid stream failed: %v", err)
	}
	expiring := *stream
	expiring.Config = stream.Config
	expiring.Config.MaxAge = time.Second
	if err := validateStream(&expiring); err == nil {
		t.Fatal("expiring stream passed")
	}

	consumer := &nats.ConsumerInfo{
		Stream: streamName,
		Name:   consumerName,
		Config: nats.ConsumerConfig{
			Durable: consumerName, DeliverPolicy: nats.DeliverAllPolicy,
			AckPolicy: nats.AckExplicitPolicy, AckWait: consumerAckWait, MaxDeliver: -1,
			FilterSubject: eventSubject, ReplayPolicy: nats.ReplayInstantPolicy,
			MaxAckPending: maxAckPending,
		},
	}
	if err := validateConsumer(consumer); err != nil {
		t.Fatalf("valid consumer failed: %v", err)
	}
	oneDelivery := *consumer
	oneDelivery.Config = consumer.Config
	oneDelivery.Config.MaxDeliver = 1
	if err := validateConsumer(&oneDelivery); err == nil {
		t.Fatal("single-delivery consumer passed")
	}
}

func jetStreamMessage(streamSequence uint64, body string) *nats.Msg {
	reply := fmt.Sprintf("$JS.ACK.%s.%s.1.%d.%d.123456789.0", streamName, consumerName, streamSequence, streamSequence)
	return &nats.Msg{Data: []byte(body), Reply: reply, Sub: &nats.Subscription{}}
}
