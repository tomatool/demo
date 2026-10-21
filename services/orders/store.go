package main

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type order struct {
	ID            string      `json:"id"`
	CustomerEmail string      `json:"customer_email"`
	Status        string      `json:"status"`
	TotalCents    int64       `json:"total_cents"`
	Currency      string      `json:"currency"`
	Items         []orderItem `json:"items"`
	CreatedAt     time.Time   `json:"created_at"`
}

type orderItem struct {
	SKU        string `json:"sku"`
	Name       string `json:"name"`
	Quantity   int32  `json:"quantity"`
	PriceCents int64  `json:"price_cents"`
}

func migrate(ctx context.Context, db *pgxpool.Pool) error {
	_, err := db.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS orders (
			id             uuid PRIMARY KEY,
			customer_email text        NOT NULL,
			status         text        NOT NULL,
			total_cents    bigint      NOT NULL,
			currency       text        NOT NULL,
			created_at     timestamptz NOT NULL
		);
		CREATE TABLE IF NOT EXISTS order_items (
			order_id    uuid   NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
			sku         text   NOT NULL,
			name        text   NOT NULL,
			quantity    int    NOT NULL,
			price_cents bigint NOT NULL
		);`)
	return err
}

type store struct {
	db *pgxpool.Pool
}

func (s *store) insert(ctx context.Context, o order) error {
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx,
			`INSERT INTO orders (id, customer_email, status, total_cents, currency, created_at)
			 VALUES ($1, $2, $3, $4, $5, $6)`,
			o.ID, o.CustomerEmail, o.Status, o.TotalCents, o.Currency, o.CreatedAt); err != nil {
			return err
		}
		for _, item := range o.Items {
			if _, err := tx.Exec(ctx,
				`INSERT INTO order_items (order_id, sku, name, quantity, price_cents) VALUES ($1, $2, $3, $4, $5)`,
				o.ID, item.SKU, item.Name, item.Quantity, item.PriceCents); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *store) get(ctx context.Context, id string) (order, error) {
	var o order
	err := s.db.QueryRow(ctx,
		`SELECT id::text, customer_email, status, total_cents, currency, created_at FROM orders WHERE id = $1`, id).
		Scan(&o.ID, &o.CustomerEmail, &o.Status, &o.TotalCents, &o.Currency, &o.CreatedAt)
	if err != nil {
		return o, err
	}
	rows, err := s.db.Query(ctx,
		`SELECT sku, name, quantity, price_cents FROM order_items WHERE order_id = $1 ORDER BY sku`, id)
	if err != nil {
		return o, err
	}
	o.Items, err = pgx.CollectRows(rows, pgx.RowToStructByPos[orderItem])
	return o, err
}

// setStatus records the outcome of an order's payment. It reports whether
// the order exists.
func (s *store) setStatus(ctx context.Context, id, status string) (bool, error) {
	tag, err := s.db.Exec(ctx, `UPDATE orders SET status = $2 WHERE id = $1`, id, status)
	return tag.RowsAffected() > 0, err
}
