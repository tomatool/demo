//! catalog owns the products: their names, prices and stock. It serves them
//! over gRPC (with reflection) from Postgres. The gateway reads products from
//! it, and orders reserves stock through it.

use std::{env, sync::Arc, time::Duration};

use tokio_postgres::{Client, NoTls};
use tonic::{transport::Server, Request, Response, Status};

pub mod pb {
    tonic::include_proto!("catalog.v1");
    pub const FILE_DESCRIPTOR_SET: &[u8] = tonic::include_file_descriptor_set!("catalog_descriptor");
}

use pb::catalog_service_server::{CatalogService, CatalogServiceServer};
use pb::{
    GetProductRequest, ListProductsRequest, ListProductsResponse, Product, ReserveStockRequest,
    Reservation,
};

const MIGRATION: &str = "
    CREATE TABLE IF NOT EXISTS products (
        sku         text PRIMARY KEY,
        name        text   NOT NULL,
        price_cents bigint NOT NULL,
        stock       int    NOT NULL CHECK (stock >= 0)
    );
    CREATE TABLE IF NOT EXISTS reservations (
        id         bigserial PRIMARY KEY,
        order_id   text        NOT NULL,
        sku        text        NOT NULL,
        quantity   int         NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    );";

struct Catalog {
    db: Arc<Client>,
}

fn product(row: &tokio_postgres::Row) -> Product {
    Product {
        sku: row.get("sku"),
        name: row.get("name"),
        price_cents: row.get("price_cents"),
        stock: row.get("stock"),
    }
}

fn internal(err: tokio_postgres::Error) -> Status {
    eprintln!("database error: {err}");
    Status::internal("database error")
}

#[tonic::async_trait]
impl CatalogService for Catalog {
    async fn get_product(&self, req: Request<GetProductRequest>) -> Result<Response<Product>, Status> {
        let sku = req.into_inner().sku;
        let row = self
            .db
            .query_opt("SELECT sku, name, price_cents, stock FROM products WHERE sku = $1", &[&sku])
            .await
            .map_err(internal)?
            .ok_or_else(|| Status::not_found(format!("no product {sku}")))?;
        Ok(Response::new(product(&row)))
    }

    async fn list_products(
        &self,
        _req: Request<ListProductsRequest>,
    ) -> Result<Response<ListProductsResponse>, Status> {
        let rows = self
            .db
            .query("SELECT sku, name, price_cents, stock FROM products ORDER BY sku", &[])
            .await
            .map_err(internal)?;
        Ok(Response::new(ListProductsResponse {
            products: rows.iter().map(product).collect(),
        }))
    }

    async fn reserve_stock(
        &self,
        req: Request<ReserveStockRequest>,
    ) -> Result<Response<Reservation>, Status> {
        let request_id = req
            .metadata()
            .get("x-request-id")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("-")
            .to_string();
        let r = req.into_inner();
        if r.sku.is_empty() || r.quantity <= 0 {
            return Err(Status::invalid_argument("sku and a positive quantity are required"));
        }

        // Take the units out of stock and record the reservation in one
        // statement, so two orders cannot both take the last unit.
        let row = self
            .db
            .query_opt(
                "WITH taken AS (
                     UPDATE products SET stock = stock - $2
                     WHERE sku = $1 AND stock >= $2
                     RETURNING stock
                 ), recorded AS (
                     INSERT INTO reservations (order_id, sku, quantity)
                     SELECT $3, $1, $2 FROM taken
                 )
                 SELECT stock FROM taken",
                &[&r.sku, &r.quantity, &r.order_id],
            )
            .await
            .map_err(internal)?;

        match row {
            Some(row) => {
                let remaining: i32 = row.get("stock");
                eprintln!(
                    "reserved {} x {} for order {} (request {request_id}), {remaining} left",
                    r.quantity, r.sku, r.order_id
                );
                Ok(Response::new(Reservation { sku: r.sku, quantity: r.quantity, remaining }))
            }
            None => {
                let exists = self
                    .db
                    .query_opt("SELECT stock FROM products WHERE sku = $1", &[&r.sku])
                    .await
                    .map_err(internal)?;
                match exists {
                    None => Err(Status::not_found(format!("no product {}", r.sku))),
                    Some(row) => {
                        let stock: i32 = row.get("stock");
                        Err(Status::failed_precondition(format!(
                            "only {stock} of {} left",
                            r.sku
                        )))
                    }
                }
            }
        }
    }
}

async fn connect(url: &str) -> Result<Client, tokio_postgres::Error> {
    let mut attempt = 0;
    loop {
        match tokio_postgres::connect(url, NoTls).await {
            Ok((client, connection)) => {
                tokio::spawn(async move {
                    if let Err(err) = connection.await {
                        eprintln!("database connection closed: {err}");
                        std::process::exit(1);
                    }
                });
                return Ok(client);
            }
            Err(err) if attempt < 30 => {
                attempt += 1;
                eprintln!("waiting for the database: {err}");
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
            Err(err) => return Err(err),
        }
    }
}

/// Resolves on Ctrl-C or SIGTERM, which is how Kubernetes, Docker and tomato
/// stop a process. Returning from main (rather than being killed) is also
/// what writes coverage data out when the binary is instrumented.
async fn shutdown() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("installing the SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
    eprintln!("catalog shutting down");
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://catalog:catalog@localhost:5432/catalog".into());
    let port = env::var("PORT").unwrap_or_else(|_| "50051".into());

    let db = connect(&url).await?;
    db.batch_execute(MIGRATION).await?;

    let reflection = tonic_reflection::server::Builder::configure()
        .register_encoded_file_descriptor_set(pb::FILE_DESCRIPTOR_SET)
        .build_v1()?;

    let addr = format!("0.0.0.0:{port}").parse()?;
    eprintln!("catalog listening on {addr}");
    Server::builder()
        .add_service(reflection)
        .add_service(CatalogServiceServer::new(Catalog { db: Arc::new(db) }))
        .serve_with_shutdown(addr, shutdown())
        .await?;
    Ok(())
}
