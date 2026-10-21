Feature: API keys
  Every /api route needs the shop's API key, and a call without one never
  reaches the services behind gateway.

  Scenario Outline: A call without the right API key is refused
    Given "gateway-client" header "X-API-Key" is "<key>"
    When "gateway-client" sends "<method>" to "<path>"
    Then "gateway-client" response status is "401"
    And "gateway-client" response json "error" is "missing or invalid API key"
    And "orders-stub" received "0" requests
    And "catalog-stub" received "0" calls

    Examples:
      | key       | method | path                |
      | wrong-key | GET    | /api/products       |
      |           | GET    | /api/products/X     |
      | wrong-key | POST   | /api/orders         |

  Scenario: The health check needs no key
    When "gateway-client" sends "GET" to "/health"
    Then "gateway-client" response status is success
    And "gateway-client" response json "status" is "ok"
