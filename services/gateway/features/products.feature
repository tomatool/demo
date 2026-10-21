Feature: Showing products
  gateway reads products from catalog over gRPC and shows them with a
  formatted price and whether they are in stock.

  Background:
    Given "gateway-client" header "X-API-Key" is "test-key"

  Scenario: A product is shown with its price
    Given "catalog-stub" stub "catalog.v1.CatalogService/GetProduct" with request json "sku" "TOMATO-1" returns json:
      """
      {"sku": "TOMATO-1", "name": "Heirloom tomato", "priceCents": "250", "stock": 10}
      """
    And "gateway-client" header "X-Request-Id" is "req-7"
    When "gateway-client" sends "GET" to "/api/products/TOMATO-1"
    Then "gateway-client" response status is "200"
    And "gateway-client" response json matches:
      """
      {"sku": "TOMATO-1", "name": "Heirloom tomato", "price": "2.50 EUR", "in_stock": true}
      """
    And "gateway-client" response header "X-Request-Id" is "req-7"
    And "catalog-stub" last "catalog.v1.CatalogService/GetProduct" request metadata "x-request-id" is "req-7"

  Scenario: A product with no stock left is shown as out of stock
    Given "catalog-stub" stub "catalog.v1.CatalogService/GetProduct" returns json:
      """
      {"sku": "BASIL-1", "name": "Basil bunch", "priceCents": "199", "stock": 0}
      """
    When "gateway-client" sends "GET" to "/api/products/BASIL-1"
    Then "gateway-client" response status is "200"
    And "gateway-client" response json "in_stock" is "false"

  Scenario: An unknown product is not found
    Given "catalog-stub" stub "catalog.v1.CatalogService/GetProduct" returns status "NOT_FOUND" with message "no product MANGO-9"
    When "gateway-client" sends "GET" to "/api/products/MANGO-9"
    Then "gateway-client" response status is "404"

  Scenario: Products are listed
    Given "catalog-stub" stub "catalog.v1.CatalogService/ListProducts" returns json:
      """
      {"products": [
        {"sku": "BASIL-1", "name": "Basil bunch", "priceCents": "199", "stock": 3},
        {"sku": "TOMATO-1", "name": "Heirloom tomato", "priceCents": "1250", "stock": 10}
      ]}
      """
    When "gateway-client" sends "GET" to "/api/products"
    Then "gateway-client" response status is "200"
    And "gateway-client" response json "products[1].price" is "12.50 EUR"
    And "catalog-stub" received "catalog.v1.CatalogService/ListProducts" "1" times

  Scenario: A catalog that is down is reported, and recovered from
    Given "catalog-stub" refuses connections
    When "gateway-client" sends "GET" to "/api/products/TOMATO-1"
    Then "gateway-client" response status is "503"
    And "gateway-client" response json "error" is "catalog is unavailable"
    When "catalog-stub" accepts connections
    And "catalog-stub" stub "catalog.v1.CatalogService/GetProduct" returns json:
      """
      {"sku": "TOMATO-1", "name": "Heirloom tomato", "priceCents": "250", "stock": 10}
      """
    And "gateway-client" sends "GET" to "/api/products/TOMATO-1"
    Then "gateway-client" response status is "200"

  Scenario: A slow catalog does not hold the caller past the deadline
    Given "catalog-stub" stub "catalog.v1.CatalogService/GetProduct" returns in sequence:
      | json                                                                       | delay |
      | {"sku": "TOMATO-1", "name": "Heirloom tomato", "priceCents": "250", "stock": 1} | 5s    |
    When "gateway-client" sends "GET" to "/api/products/TOMATO-1"
    Then "gateway-client" response status is "504"
    And "gateway-client" response json "error" is "catalog timed out"
    And "gateway-client" response time is less than "3s"

  Scenario: Many shoppers at once are all served
    Given "catalog-stub" stub "catalog.v1.CatalogService/GetProduct" returns json:
      """
      {"sku": "TOMATO-1", "name": "Heirloom tomato", "priceCents": "250", "stock": 10}
      """
    When "gateway-client" sends "20" concurrent "GET" to "/api/products/TOMATO-1"
    Then "gateway-client" "20" of the concurrent responses have status "200"
    And "catalog-stub" received "catalog.v1.CatalogService/GetProduct" "20" times
