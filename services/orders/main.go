// Command orders takes orders over HTTP. It prices and reserves every item
// with the catalog service over gRPC, stores the order in Postgres, announces
// it on the Kafka topic orders.created, and follows the payment of each order
// from the RabbitMQ exchange payments.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	catalogv1 "github.com/tomatool/demo/services/orders/gen/catalog/v1"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("orders stopped", "error", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	db, err := pgxpool.New(ctx, env("DATABASE_URL", "postgres://orders:orders@localhost:5432/orders?sslmode=disable"))
	if err != nil {
		return err
	}
	defer db.Close()
	if err := migrate(ctx, db); err != nil {
		return err
	}

	conn, err := grpc.NewClient(env("CATALOG_ADDR", "localhost:50051"),
		grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	defer conn.Close()

	events := newPublisher(env("KAFKA_BROKERS", "localhost:9092"), env("KAFKA_TOPIC", "orders.created"))
	defer events.Close()

	go consumePayments(ctx, log, db, env("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/"))

	srv := &http.Server{
		Addr: ":" + env("PORT", "8080"),
		Handler: (&api{
			log:     log,
			store:   &store{db: db},
			catalog: catalogv1.NewCatalogServiceClient(conn),
			events:  events,
		}).routes(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdown)
	}()

	log.Info("orders listening", "addr", srv.Addr)
	if err := srv.ListenAndServe(); err != http.ErrServerClosed {
		return err
	}
	return nil
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
