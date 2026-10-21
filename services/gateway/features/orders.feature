Feature: Placing and reading orders
  gateway forwards orders to the orders service unchanged, with a request id
  that follows the order through every service.

  Background:
    Given "api" header "X-API-Key" is "test-key"

  Scenario: An order is forwarded with the caller's request id
    Given "orders" stub "POST" "/orders" returns "201" with json:
      """
      {"id": "0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10", "status": "pending", "total_cents": 1000}
      """
    And "api" header "X-Request-Id" is "req-42"
    When "api" sends "POST" to "/api/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 4}]}
      """
    Then "api" response status is "201"
    And "api" response json "status" is "pending"
    And "orders" received "POST" "/orders" with header "X-Request-Id" "req-42"
    And "orders" last "POST" "/orders" request json contains:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 4}]}
      """

  Scenario: An order without a request id is given one
    Given "orders" stub "POST" "/orders" returns "201" with json:
      """
      {"id": "0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10"}
      """
    When "api" sends "POST" to "/api/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 1}]}
      """
    Then "api" response status is "201"
    And "api" response header "X-Request-Id" saved as "{{request_id}}"
    And "orders" received "POST" "/orders" with header "X-Request-Id" "{{request_id}}"

  Scenario: orders' refusal reaches the caller unchanged
    Given "orders" stub "POST" "/orders" returns "409" with json:
      """
      {"error": "product TOMATO-1 is out of stock"}
      """
    When "api" sends "POST" to "/api/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 99}]}
      """
    Then "api" response status is "409"
    And "api" response json "error" is "product TOMATO-1 is out of stock"

  Scenario: An order is read back
    Given "orders" stub "GET" "/orders/0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10" returns "200" with json:
      """
      {"id": "0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10", "status": "paid"}
      """
    When "api" sends "GET" to "/api/orders/0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10"
    Then "api" response status is "200"
    And "api" response json "status" is "paid"

  Scenario: orders being down is reported as a bad gateway
    Given "orders" refuses connections
    When "api" sends "POST" to "/api/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 1}]}
      """
    Then "api" response status is "502"
    And "api" response json "error" is "orders is unavailable"
