Feature: Placing and reading orders
  gateway forwards orders to the orders service unchanged, with a request id
  that follows the order through every service.

  Background:
    Given "gateway-client" header "X-API-Key" is "test-key"

  Scenario: An order is forwarded with the caller's request id
    Given "orders-stub" stub "POST" "/orders" returns "201" with json:
      """
      {"id": "0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10", "status": "pending", "total_cents": 1000}
      """
    And "gateway-client" header "X-Request-Id" is "req-42"
    When "gateway-client" sends "POST" to "/api/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 4}]}
      """
    Then "gateway-client" response status is "201"
    And "gateway-client" response json "status" is "pending"
    And "orders-stub" received "POST" "/orders" with header "X-Request-Id" "req-42"
    And "orders-stub" last "POST" "/orders" request json contains:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 4}]}
      """

  Scenario: An order without a request id is given one
    Given "orders-stub" stub "POST" "/orders" returns "201" with json:
      """
      {"id": "0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10"}
      """
    When "gateway-client" sends "POST" to "/api/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 1}]}
      """
    Then "gateway-client" response status is "201"
    And "gateway-client" response header "X-Request-Id" saved as "{{request_id}}"
    And "orders-stub" received "POST" "/orders" with header "X-Request-Id" "{{request_id}}"

  Scenario: orders' refusal reaches the caller unchanged
    Given "orders-stub" stub "POST" "/orders" returns "409" with json:
      """
      {"error": "product TOMATO-1 is out of stock"}
      """
    When "gateway-client" sends "POST" to "/api/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 99}]}
      """
    Then "gateway-client" response status is "409"
    And "gateway-client" response json "error" is "product TOMATO-1 is out of stock"

  Scenario: An order is read back
    Given "orders-stub" stub "GET" "/orders/0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10" returns "200" with json:
      """
      {"id": "0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10", "status": "paid"}
      """
    When "gateway-client" sends "GET" to "/api/orders/0b6f3b7e-6c55-4d1e-9a51-5d6c0f3f2a10"
    Then "gateway-client" response status is "200"
    And "gateway-client" response json "status" is "paid"

  Scenario: orders being down is reported as a bad gateway
    Given "orders-stub" refuses connections
    When "gateway-client" sends "POST" to "/api/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 1}]}
      """
    Then "gateway-client" response status is "502"
    And "gateway-client" response json "error" is "orders is unavailable"
