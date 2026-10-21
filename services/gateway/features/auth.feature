Feature: API keys
  Every /api route needs the shop's API key, and a call without one never
  reaches the services behind gateway.

  Scenario Outline: A call without the right API key is refused
    Given "api" header "X-API-Key" is "<key>"
    When "api" sends "<method>" to "<path>"
    Then "api" response status is "401"
    And "api" response json "error" is "missing or invalid API key"
    And "orders" received "0" requests
    And "catalog" received "0" calls

    Examples:
      | key       | method | path                |
      | wrong-key | GET    | /api/products       |
      |           | GET    | /api/products/X     |
      | wrong-key | POST   | /api/orders         |

  Scenario: The health check needs no key
    When "api" sends "GET" to "/health"
    Then "api" response status is success
    And "api" response json "status" is "ok"
