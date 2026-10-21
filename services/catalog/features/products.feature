Feature: Reading products
  gateway shows products and orders prices them, both through catalog's gRPC
  API.

  Background:
    Given "db" table "products" has values:
      | sku      | name            | price_cents | stock |
      | TOMATO-1 | Heirloom tomato | 250         | 10    |
      | BASIL-1  | Basil bunch     | 199         | 3     |

  Scenario: catalog describes itself over reflection
    Then "grpc" exposes service "catalog.v1.CatalogService"
    And "grpc" service "catalog.v1.CatalogService" has method "ReserveStock"

  Scenario: A product is read by its sku
    When "grpc" calls "catalog.v1.CatalogService/GetProduct" with:
      """
      {"sku": "TOMATO-1"}
      """
    Then "grpc" call succeeds
    And "grpc" response json matches:
      """
      {"sku": "TOMATO-1", "name": "Heirloom tomato", "priceCents": "250", "stock": 10}
      """
    And "grpc" response time is less than "500ms"

  Scenario: An unknown sku is not found
    When "grpc" calls "catalog.v1.CatalogService/GetProduct" with:
      """
      {"sku": "MANGO-9"}
      """
    Then "grpc" call fails
    And "grpc" response status is "NOT_FOUND"
    And "grpc" response error contains "no product MANGO-9"

  Scenario: Products are listed by sku
    When "grpc" calls "catalog.v1.CatalogService/ListProducts"
    Then "grpc" call succeeds
    And "grpc" response json "products[0].sku" is "BASIL-1"
    And "grpc" response json "products[1].sku" is "TOMATO-1"
    And "grpc" response json "products[2]" does not exist
