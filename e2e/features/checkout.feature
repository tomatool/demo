Feature: Checkout, across every service
  A shopper orders through gateway. orders reserves stock in catalog over
  gRPC and announces the order on Kafka; payments reads it with MSK IAM auth,
  charges it with Stripe and publishes the outcome on RabbitMQ; orders records
  it, and notifications emails the shopper through SendGrid, archives the email
  in S3 and alerts Slack when a payment failed.

  Background:
    Given "catalog-db" table "products" has values:
      | sku      | name            | price_cents | stock |
      | TOMATO-1 | Heirloom tomato | 250         | 10    |
      | TRUFFLE  | White truffle   | 250000      | 2     |
    # WireMock keeps what it was asked across scenarios; tomato does not know
    # to reset it, so the scenario does.
    And "stripe" sends "DELETE" to "/__admin/requests"
    And "sendgrid" sends "DELETE" to "/__admin/requests"
    And "slack" sends "DELETE" to "/__admin/requests"
    And "shop" header "X-API-Key" is "e2e-key"

  Scenario: A paid order is confirmed to the shopper
    When "shop" sends "POST" to "/api/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TOMATO-1", "quantity": 4}]}
      """
    Then "shop" response status is "201"
    And "shop" response json "total_cents" is "1000"
    And "shop" response json "id" saved as "{{order_id}}"

    # catalog took the units out of stock.
    And "catalog-db" query "SELECT stock FROM products WHERE sku = 'TOMATO-1'" returns:
      | stock |
      | 6     |

    # payments charged the order, and orders heard about it.
    And "orders-db" query "SELECT status FROM orders" returns within "60s":
      | status |
      | paid   |
    And "stripe" sends "POST" to "/__admin/requests/count" with json:
      """
      {"method": "POST", "url": "/v1/payment_intents"}
      """
    And "stripe" response json "count" is "1"

    # notifications emailed the shopper.
    And "notifications-db" query "SELECT kind, recipient, status FROM notifications" returns within "60s":
      | kind            | recipient       | status |
      | order_confirmed | ada@example.com | sent   |
    And "sendgrid" sends "POST" to "/__admin/requests/count" with json:
      """
      {"method": "POST", "url": "/v3/mail/send"}
      """
    And "sendgrid" response json "count" is "1"
    And "archive" bucket "email-archive" should have "1" objects with prefix "{{order_id}}/"

    # And the shopper sees it paid.
    When "shop" sends "GET" to "/api/orders/{{order_id}}"
    Then "shop" response status is "200"
    And "shop" response json "status" is "paid"

  Scenario: A declined payment is explained to the shopper
    When "shop" sends "POST" to "/api/orders" with json:
      """
      {"customer_email": "bob@example.com", "items": [{"sku": "TRUFFLE", "quantity": 1}]}
      """
    Then "shop" response status is "201"
    And "orders-db" query "SELECT status FROM orders" returns within "60s":
      | status         |
      | payment_failed |
    And "notifications-db" query "SELECT kind, recipient, subject FROM notifications" returns within "60s":
      | kind           | recipient       | subject                        |
      | payment_failed | bob@example.com | We could not take your payment |
    And "slack" sends "POST" to "/__admin/requests/count" with json:
      """
      {"method": "POST", "urlPathPattern": "/services/.*"}
      """
    And "slack" response json "count" is "1"

  Scenario: An order the stock cannot cover never reaches payments
    When "shop" sends "POST" to "/api/orders" with json:
      """
      {"customer_email": "ada@example.com", "items": [{"sku": "TRUFFLE", "quantity": 3}]}
      """
    Then "shop" response status is "409"
    And "shop" response json "error" is "product TRUFFLE is out of stock"
    And "orders-db" table "orders" is empty
    And "stripe" sends "POST" to "/__admin/requests/count" with json:
      """
      {"method": "POST", "url": "/v1/payment_intents"}
      """
    And "stripe" response json "count" is "0"

  Scenario: A product is shown from catalog
    When "shop" sends "GET" to "/api/products/TOMATO-1"
    Then "shop" response status is "200"
    And "shop" response json matches:
      """
      {"sku": "TOMATO-1", "name": "Heirloom tomato", "price": "2.50 EUR", "in_stock": true}
      """
