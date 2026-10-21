Feature: Reserving stock
  orders reserves every item of an order. A reservation takes the units out of
  stock and is recorded, and a reservation the stock cannot cover changes
  nothing.

  Background:
    Given "db" table "products" has values:
      | sku      | name            | price_cents | stock |
      | TOMATO-1 | Heirloom tomato | 250         | 10    |
      | BASIL-1  | Basil bunch     | 199         | 3     |

  Scenario: A reservation takes units out of stock
    Given "grpc" metadata "x-request-id" is "req-42"
    When "grpc" calls "catalog.v1.CatalogService/ReserveStock" with:
      """
      {"sku": "TOMATO-1", "quantity": 4, "orderId": "order-1"}
      """
    Then "grpc" call succeeds
    And "grpc" response json contains:
      """
      {"sku": "TOMATO-1", "quantity": 4, "remaining": 6}
      """
    And "db" query "SELECT stock FROM products WHERE sku = 'TOMATO-1'" returns:
      | stock |
      | 6     |
    And "db" table "reservations" contains:
      | order_id | sku      | quantity |
      | order-1  | TOMATO-1 | 4        |

  Scenario: The last units can be reserved
    When "grpc" calls "catalog.v1.CatalogService/ReserveStock" with:
      """
      {"sku": "BASIL-1", "quantity": 3, "orderId": "order-2"}
      """
    Then "grpc" call succeeds
    And "grpc" response json "remaining" is "0"

  Scenario: More than is in stock is refused and nothing changes
    When "grpc" calls "catalog.v1.CatalogService/ReserveStock" with:
      """
      {"sku": "BASIL-1", "quantity": 4, "orderId": "order-3"}
      """
    Then "grpc" call fails
    And "grpc" response status is "FAILED_PRECONDITION"
    And "grpc" response error contains "only 3 of BASIL-1 left"
    And "db" query "SELECT stock FROM products WHERE sku = 'BASIL-1'" returns:
      | stock |
      | 3     |
    And "db" table "reservations" is empty

  Scenario Outline: A reservation without a sku or a positive quantity is invalid
    When "grpc" calls "catalog.v1.CatalogService/ReserveStock" with:
      """
      <request>
      """
    Then "grpc" response status is "<status>"
    And "db" table "reservations" is empty

    Examples:
      | request                                           | status           |
      | {"sku": "", "quantity": 1, "orderId": "o"}        | INVALID_ARGUMENT |
      | {"sku": "TOMATO-1", "quantity": 0, "orderId": "o"} | INVALID_ARGUMENT |
      | {"sku": "MANGO-9", "quantity": 1, "orderId": "o"} | NOT_FOUND        |
