Feature: Placing an order
  orders prices and reserves every item with the catalog over gRPC, stores the
  order, and announces it on Kafka for payments to charge.

  Background:
    Given "orders-events" consumes from "orders.created"
    And "catalog-stub" stub "catalog.v1.CatalogService/GetProduct" with request json "sku" "TOMATO-1" returns json:
      """
      {"sku": "TOMATO-1", "name": "Heirloom tomato", "priceCents": "250", "stock": 10}
      """
    And "catalog-stub" stub "catalog.v1.CatalogService/GetProduct" with request json "sku" "BASIL-1" returns json:
      """
      {"sku": "BASIL-1", "name": "Basil bunch", "priceCents": "199", "stock": 3}
      """
    And "catalog-stub" stub "catalog.v1.CatalogService/ReserveStock" returns json:
      """
      {"remaining": 1}
      """

  Scenario: An order is priced, reserved, stored and announced
    Given "orders-client" header "X-Request-Id" is "req-42"
    When "orders-client" sends "POST" to "/orders" with json:
      """
      {
        "customer_email": "ada@example.com",
        "items": [
          {"sku": "TOMATO-1", "quantity": 4},
          {"sku": "BASIL-1", "quantity": 1}
        ]
      }
      """
    Then "orders-client" response status is "201"
    And "orders-client" response json "id" is uuid
    And "orders-client" response json "status" is "pending"
    And "orders-client" response json "total_cents" is "1199"
    And "orders-client" response json "items[0].name" is "Heirloom tomato"
    And "orders-client" response json "id" saved as "{{order_id}}"

    # What orders asked the catalog for, and that the request id went along.
    And "catalog-stub" received "catalog.v1.CatalogService/ReserveStock" "2" times
    And "catalog-stub" last "catalog.v1.CatalogService/ReserveStock" request json contains:
      """
      {"sku": "BASIL-1", "quantity": 1, "orderId": "{{order_id}}"}
      """
    And "catalog-stub" received "catalog.v1.CatalogService/GetProduct" with metadata "x-request-id" "req-42"

    # The effects: a row in orders' database and an event on Kafka.
    And "orders-db" query "SELECT customer_email, status, total_cents FROM orders" returns:
      | customer_email  | status  | total_cents |
      | ada@example.com | pending | 1199        |
    And "orders-db" table "order_items" has "2" rows
    And "orders-events" receives from "orders.created" within "10s"
    # Kafka assertions compare text, so they check fragments of the event.
    And "orders-events" last message contains:
      """
      "customer_email":"ada@example.com"
      """
    And "orders-events" last message contains:
      """
      "total_cents":1199
      """
    And "orders-events" last message has header "x-request-id" with value "req-42"

  Scenario: An unknown product is refused and nothing is stored
    Given "catalog-stub" stub "catalog.v1.CatalogService/GetProduct" with request json "sku" "MANGO-9" returns status "NOT_FOUND" with message "no product MANGO-9"
    When "orders-client" sends "POST" to "/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "MANGO-9", "quantity": 1}]}
      """
    Then "orders-client" response status is "422"
    And "orders-client" response json "error" is "unknown product MANGO-9"
    And "catalog-stub" did not receive "catalog.v1.CatalogService/ReserveStock"
    And "orders-db" table "orders" is empty
    And "orders-events" topic "orders.created" is empty

  Scenario: A product that is out of stock is refused
    Given "catalog-stub" stub "catalog.v1.CatalogService/ReserveStock" with request json "sku" "TOMATO-1" returns status "FAILED_PRECONDITION" with message "only 2 left"
    When "orders-client" sends "POST" to "/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 5}]}
      """
    Then "orders-client" response status is "409"
    And "orders-client" response body contains "out of stock"
    And "orders-db" table "orders" is empty

  Scenario: The catalog being down is reported, not hidden
    Given "catalog-stub" refuses connections
    When "orders-client" sends "POST" to "/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 1}]}
      """
    Then "orders-client" response status is "503"
    And "orders-client" response json "error" is "catalog is unavailable"
    And "orders-db" table "orders" is empty

  Scenario Outline: A malformed order is refused before anything is reserved
    When "orders-client" sends "POST" to "/orders" with body:
      """
      <body>
      """
    Then "orders-client" response status is "400"
    And "orders-client" response json "error" is "<error>"
    And "catalog-stub" received "0" calls

    Examples:
      | body                                                                   | error                                              |
      | {"items": [{"sku": "TOMATO-1", "quantity": 1}]}                        | customer_email is required                         |
      | {"customer_email": "ada@example.com", "items": []}                     | an order needs at least one item                   |
      | {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1"}]}  | every item needs a sku and a positive quantity     |
      | not json                                                               | body is not valid JSON                             |
