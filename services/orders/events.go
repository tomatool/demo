package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	amqp "github.com/rabbitmq/amqp091-go"
	"github.com/segmentio/kafka-go"
)

// publisher announces new orders on Kafka.
type publisher struct {
	writer *kafka.Writer
}

func newPublisher(brokers, topic string) *publisher {
	return &publisher{writer: &kafka.Writer{
		Addr:                   kafka.TCP(strings.Split(brokers, ",")...),
		Topic:                  topic,
		Balancer:               &kafka.Hash{},
		RequiredAcks:           kafka.RequireOne,
		AllowAutoTopicCreation: true,
		BatchTimeout:           10 * time.Millisecond,
	}}
}

// orderCreated is the event payments charges the customer from. It is keyed by
// the order id, so every event about one order lands on the same partition.
func (p *publisher) orderCreated(ctx context.Context, o order, requestID string) error {
	value, err := json.Marshal(map[string]any{
		"order_id":       o.ID,
		"customer_email": o.CustomerEmail,
		"total_cents":    o.TotalCents,
		"currency":       o.Currency,
		"items":          o.Items,
	})
	if err != nil {
		return err
	}
	return p.writer.WriteMessages(ctx, kafka.Message{
		Key:   []byte(o.ID),
		Value: value,
		Headers: []kafka.Header{
			{Key: "event-type", Value: []byte("order.created")},
			{Key: "x-request-id", Value: []byte(requestID)},
		},
	})
}

func (p *publisher) Close() error { return p.writer.Close() }

// consumePayments follows the payments exchange and records each order's
// payment outcome. It reconnects until ctx ends.
func consumePayments(ctx context.Context, log *slog.Logger, db *pgxpool.Pool, url string) {
	s := &store{db: db}
	for ctx.Err() == nil {
		if err := consumeOnce(ctx, log, s, url); err != nil && ctx.Err() == nil {
			log.Warn("payments consumer disconnected, retrying", "error", err)
			select {
			case <-ctx.Done():
			case <-time.After(time.Second):
			}
		}
	}
}

func consumeOnce(ctx context.Context, log *slog.Logger, s *store, url string) error {
	conn, err := amqp.Dial(url)
	if err != nil {
		return err
	}
	defer conn.Close()
	ch, err := conn.Channel()
	if err != nil {
		return err
	}
	if err := ch.ExchangeDeclare("payments", "topic", true, false, false, false, nil); err != nil {
		return err
	}
	q, err := ch.QueueDeclare("orders.payments", true, false, false, false, nil)
	if err != nil {
		return err
	}
	if err := ch.QueueBind(q.Name, "payment.*", "payments", false, nil); err != nil {
		return err
	}
	deliveries, err := ch.ConsumeWithContext(ctx, q.Name, "orders", false, false, false, false, nil)
	if err != nil {
		return err
	}
	log.Info("consuming payment events", "queue", q.Name)

	closed := conn.NotifyClose(make(chan *amqp.Error, 1))
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-closed:
			return err
		case d, ok := <-deliveries:
			if !ok {
				return nil
			}
			handlePayment(ctx, log, s, d)
		}
	}
}

var paymentStatus = map[string]string{
	"payment.succeeded": "paid",
	"payment.failed":    "payment_failed",
}

func handlePayment(ctx context.Context, log *slog.Logger, s *store, d amqp.Delivery) {
	status, known := paymentStatus[d.RoutingKey]
	var event struct {
		OrderID string `json:"order_id"`
	}
	if err := json.Unmarshal(d.Body, &event); !known || err != nil || uuid.Validate(event.OrderID) != nil {
		log.Warn("dropping payment event", "routing_key", d.RoutingKey, "body", string(d.Body))
		d.Reject(false)
		return
	}
	found, err := s.setStatus(ctx, event.OrderID, status)
	if err != nil {
		log.Error("recording payment", "order_id", event.OrderID, "error", err)
		d.Nack(false, true)
		return
	}
	if !found {
		log.Warn("payment for an unknown order", "order_id", event.OrderID)
	} else {
		log.Info("order payment recorded", "order_id", event.OrderID, "status", status)
	}
	d.Ack(false)
}
