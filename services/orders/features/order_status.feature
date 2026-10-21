Feature: Following an order
  An order can be read back, and its status follows the payment events that
  payments publishes on the RabbitMQ exchange "payments".

  Background:
    Given "orders-db" table "orders" has values:
      | id                                   | customer_email  | status  | total_cents | currency | created_at           |
      | 0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10 | ada@example.com | pending | 1199        | EUR      | 2026-10-21T09:00:00Z |
    And "orders-db" table "order_items" has values:
      | order_id                             | sku      | name            | quantity | price_cents |
      | 0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10 | TOMATO-1 | Heirloom tomato | 4        | 250         |
      | 0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10 | BASIL-1  | Basil bunch     | 1        | 199         |

  Scenario: An order is read back with its items
    When "orders-client" sends "GET" to "/orders/0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10"
    Then "orders-client" response status is "200"
    And "orders-client" response json matches:
      """
      {
        "id": "0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10",
        "customer_email": "ada@example.com",
        "status": "pending",
        "total_cents": 1199,
        "currency": "EUR",
        "items": [
          {"sku": "BASIL-1", "name": "Basil bunch", "quantity": 1, "price_cents": 199},
          {"sku": "TOMATO-1", "name": "Heirloom tomato", "quantity": 4, "price_cents": 250}
        ],
        "created_at": "@notempty"
      }
      """

  Scenario: An order that does not exist is not found
    When "orders-client" sends "GET" to "/orders/7d1c8a52-0000-4000-8000-000000000000"
    Then "orders-client" response status is "404"

  Scenario Outline: The payment outcome becomes the order's status
    When "payments-queue" publishes json to exchange "payments" with routing key "<routing key>":
      """
      {"order_id": "0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10", "payment_id": "pay_123"}
      """
    Then "orders-db" query "SELECT status FROM orders WHERE id = '0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10'" returns within "10s":
      | status   |
      | <status> |

    Examples:
      | routing key       | status         |
      | payment.succeeded | paid           |
      | payment.failed    | payment_failed |
