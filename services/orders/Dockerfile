# Build context: the repository root.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY services/orders/go.mod services/orders/go.sum ./
RUN go mod download
COPY services/orders ./
RUN CGO_ENABLED=0 go build -o /orders .

FROM alpine:3.22
COPY --from=build /orders /usr/local/bin/orders
EXPOSE 8080
CMD ["orders"]
