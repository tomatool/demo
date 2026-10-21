# Build a service and run its tomato suite:  make orders
# Run every service together:                make e2e
# Regenerate code from proto/:               make proto
#
# Needs Docker, tomato (https://github.com/tomatool/tomato) and each
# service's toolchain: Node 22, Go, Rust + protoc, JDK 17, Python 3.12.

SERVICES := gateway orders catalog payments notifications

.PHONY: all $(SERVICES) e2e coverage proto $(addprefix build-,$(SERVICES))

all: $(SERVICES)

build-gateway:
	cd services/gateway && npm ci && npm test
build-orders:
	cd services/orders && go test ./... && go build -o bin/orders .
build-catalog:
	cd services/catalog && cargo test && cargo build --release
build-payments:
	cd services/payments && ./gradlew test installDist
build-notifications:
	cd services/notifications && python3 -m venv .venv && .venv/bin/pip install -q -e '.[test]' && .venv/bin/python -m pytest -q

$(SERVICES): %: build-%
	cd services/$@ && tomato run

e2e: build-gateway
	cd e2e && tomato run

coverage:
	@for dir in $(addprefix services/,$(SERVICES)) e2e; do echo "== $$dir"; (cd $$dir && tomato coverage | head -1); done

proto:
	protoc --include_imports --descriptor_set_out=proto/catalog.binpb -I proto proto/catalog/v1/catalog.proto
	protoc -I proto --go_out=services/orders/gen --go_opt=paths=source_relative \
		--go-grpc_out=services/orders/gen --go-grpc_opt=paths=source_relative proto/catalog/v1/catalog.proto
