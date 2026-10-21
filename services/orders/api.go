package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	catalogv1 "github.com/tomatool/demo/services/orders/gen/catalog/v1"
)

type api struct {
	log     *slog.Logger
	store   *store
	catalog catalogv1.CatalogServiceClient
	events  *publisher
}

func (a *api) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", a.health)
	mux.HandleFunc("POST /orders", a.createOrder)
	mux.HandleFunc("GET /orders/{id}", a.getOrder)
	return mux
}

type createOrderRequest struct {
	CustomerEmail string `json:"customer_email"`
	Items         []struct {
		SKU      string `json:"sku"`
		Quantity int32  `json:"quantity"`
	} `json:"items"`
}

func (a *api) health(w http.ResponseWriter, r *http.Request) {
	if err := a.store.db.Ping(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *api) createOrder(w http.ResponseWriter, r *http.Request) {
	var req createOrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "body is not valid JSON")
		return
	}
	if !strings.Contains(req.CustomerEmail, "@") {
		writeError(w, http.StatusBadRequest, "customer_email is required")
		return
	}
	if len(req.Items) == 0 {
		writeError(w, http.StatusBadRequest, "an order needs at least one item")
		return
	}

	requestID := r.Header.Get("X-Request-Id")
	if requestID == "" {
		requestID = uuid.NewString()
	}
	order := order{
		ID:            uuid.NewString(),
		CustomerEmail: req.CustomerEmail,
		Status:        "pending",
		Currency:      "EUR",
		CreatedAt:     time.Now().UTC(),
	}

	// The request id travels with every call this order causes, so one id
	// finds the order in the logs of every service.
	ctx := metadata.AppendToOutgoingContext(r.Context(), "x-request-id", requestID)
	for _, item := range req.Items {
		if item.SKU == "" || item.Quantity <= 0 {
			writeError(w, http.StatusBadRequest, "every item needs a sku and a positive quantity")
			return
		}
		line, err := a.reserve(ctx, order.ID, item.SKU, item.Quantity)
		if err != nil {
			a.catalogError(w, item.SKU, err)
			return
		}
		order.Items = append(order.Items, line)
		order.TotalCents += line.PriceCents * int64(line.Quantity)
	}

	if err := a.store.insert(r.Context(), order); err != nil {
		a.log.Error("storing order", "error", err)
		writeError(w, http.StatusInternalServerError, "could not store the order")
		return
	}
	if err := a.events.orderCreated(r.Context(), order, requestID); err != nil {
		a.log.Error("publishing orders.created", "order_id", order.ID, "error", err)
		writeError(w, http.StatusInternalServerError, "could not publish the order")
		return
	}

	a.log.Info("order created", "order_id", order.ID, "request_id", requestID, "total_cents", order.TotalCents)
	writeJSON(w, http.StatusCreated, order)
}

// reserve prices an item and takes it out of stock.
func (a *api) reserve(ctx context.Context, orderID, sku string, quantity int32) (orderItem, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()

	product, err := a.catalog.GetProduct(ctx, &catalogv1.GetProductRequest{Sku: sku})
	if err != nil {
		return orderItem{}, err
	}
	if _, err := a.catalog.ReserveStock(ctx, &catalogv1.ReserveStockRequest{
		Sku: sku, Quantity: quantity, OrderId: orderID,
	}); err != nil {
		return orderItem{}, err
	}
	return orderItem{SKU: sku, Name: product.Name, Quantity: quantity, PriceCents: product.PriceCents}, nil
}

func (a *api) catalogError(w http.ResponseWriter, sku string, err error) {
	switch status.Code(err) {
	case codes.NotFound:
		writeError(w, http.StatusUnprocessableEntity, fmt.Sprintf("unknown product %s", sku))
	case codes.FailedPrecondition:
		writeError(w, http.StatusConflict, fmt.Sprintf("product %s is out of stock", sku))
	default:
		a.log.Error("calling catalog", "sku", sku, "error", err)
		writeError(w, http.StatusServiceUnavailable, "catalog is unavailable")
	}
}

func (a *api) getOrder(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := uuid.Parse(id); err != nil {
		writeError(w, http.StatusNotFound, "order not found")
		return
	}
	order, err := a.store.get(r.Context(), id)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "order not found")
		return
	}
	if err != nil {
		a.log.Error("reading order", "order_id", id, "error", err)
		writeError(w, http.StatusInternalServerError, "could not read the order")
		return
	}
	writeJSON(w, http.StatusOK, order)
}

func writeJSON(w http.ResponseWriter, code int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, code int, message string) {
	writeJSON(w, code, map[string]string{"error": message})
}
