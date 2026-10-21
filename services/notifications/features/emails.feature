Feature: Emailing customers about their payments
  notifications emails the customer through SendGrid once for every payment
  outcome payments publishes, archives the email in S3, and records it.

  Background:
    Given "sendgrid-stub" stub "POST" "/v3/mail/send" returns "202"
    And "slack-stub" stub "POST" "/services/T000/B000/XXXX" returns "200" with body:
      """
      ok
      """

  Scenario: A successful payment confirms the order by email
    Given "payments-queue" message header "x-request-id" is "req-42"
    When "payments-queue" publishes json to exchange "payments" with routing key "payment.succeeded":
      """
      {"order_id": "order-1", "customer_email": "ada@example.com", "amount_cents": 1199, "currency": "EUR", "payment_id": "pi_1"}
      """
    Then "notifications-db" query "SELECT order_id, kind, recipient, status FROM notifications" returns within "10s":
      | order_id | kind            | recipient       | status |
      | order-1  | order_confirmed | ada@example.com | sent   |

    # The email, as SendGrid's v3 Mail Send API takes it.
    And "sendgrid-stub" received "POST" "/v3/mail/send" "1" times
    And "sendgrid-stub" received "POST" "/v3/mail/send" with header "Authorization" "Bearer SG.test-key"
    And "sendgrid-stub" received "POST" "/v3/mail/send" with header "X-Request-Id" "req-42"
    And "sendgrid-stub" last "POST" "/v3/mail/send" request json contains:
      """
      {
        "personalizations": [{"to": [{"email": "ada@example.com"}]}],
        "from": {"email": "shop@example.com"},
        "subject": "Your order is confirmed",
        "content": [{"type": "text/plain", "value": "Thank you! We received 11.99 EUR for order order-1."}]
      }
      """

    # A copy in the archive, and no alert: nothing went wrong.
    And "archive-storage" object "email-archive/order-1/order_confirmed.json" content should match:
      """
      {"to": "ada@example.com", "subject": "Your order is confirmed", "text": "@notempty", "status": "sent"}
      """
    And "archive-storage" object "email-archive/order-1/order_confirmed.json" content type should be "application/json"
    And "slack-stub" received "0" requests

  Scenario: A failed payment tells the customer why and alerts the team
    When "payments-queue" publishes json to exchange "payments" with routing key "payment.failed":
      """
      {"order_id": "order-2", "customer_email": "ada@example.com", "amount_cents": 500, "currency": "EUR", "reason": "card_declined"}
      """
    Then "notifications-db" query "SELECT kind, status FROM notifications WHERE order_id = 'order-2'" returns within "10s":
      | kind           | status |
      | payment_failed | sent   |
    And "sendgrid-stub" received request with body containing "your card was declined"
    And "slack-stub" last "POST" "/services/T000/B000/XXXX" request json contains:
      """
      {"text": ":warning: Payment failed for order order-2 (ada@example.com): card_declined"}
      """
    And "archive-storage" bucket "email-archive" should have "1" objects with prefix "order-2/"

  Scenario: The same event delivered twice sends one email
    When "payments-queue" publishes json to exchange "payments" with routing key "payment.succeeded":
      """
      {"order_id": "order-3", "customer_email": "ada@example.com", "amount_cents": 250, "currency": "EUR"}
      """
    And "payments-queue" publishes json to exchange "payments" with routing key "payment.succeeded":
      """
      {"order_id": "order-3", "customer_email": "ada@example.com", "amount_cents": 250, "currency": "EUR"}
      """
    # Events are handled one at a time, in order: once this one is recorded,
    # the duplicate before it has been handled too.
    And "payments-queue" publishes json to exchange "payments" with routing key "payment.succeeded":
      """
      {"order_id": "order-4", "customer_email": "bob@example.com", "amount_cents": 250, "currency": "EUR"}
      """
    Then "notifications-db" query "SELECT order_id FROM notifications WHERE order_id = 'order-4'" returns within "10s":
      | order_id |
      | order-4  |
    And "notifications-db" table "notifications" has "2" rows
    And "sendgrid-stub" received "POST" "/v3/mail/send" "2" times
    And "archive-storage" bucket "email-archive" should have "2" objects

  Scenario: SendGrid failing for a moment is retried
    Given "sendgrid-stub" stub "POST" "/v3/mail/send" returns in sequence:
      | status |
      | 503    |
      | 202    |
    When "payments-queue" publishes json to exchange "payments" with routing key "payment.succeeded":
      """
      {"order_id": "order-5", "customer_email": "ada@example.com", "amount_cents": 250, "currency": "EUR"}
      """
    Then "notifications-db" query "SELECT status FROM notifications WHERE order_id = 'order-5'" returns within "10s":
      | status |
      | sent   |
    And "sendgrid-stub" received "POST" "/v3/mail/send" "2" times

  Scenario: An address SendGrid refuses is recorded, not retried
    Given "sendgrid-stub" stub "POST" "/v3/mail/send" returns "400" with json:
      """
      {"errors": [{"message": "Does not contain a valid address.", "field": "personalizations.0.to.0.email"}]}
      """
    When "payments-queue" publishes json to exchange "payments" with routing key "payment.succeeded":
      """
      {"order_id": "order-6", "customer_email": "not-an-address", "amount_cents": 250, "currency": "EUR"}
      """
    Then "notifications-db" query "SELECT status FROM notifications WHERE order_id = 'order-6'" returns within "10s":
      | status   |
      | rejected |
    And "sendgrid-stub" received "POST" "/v3/mail/send" "1" times
    And "archive-storage" object "email-archive/order-6/order_confirmed.json" content should contain "rejected"

  Scenario: An event notifications cannot read is dropped without blocking the next
    When "payments-queue" publishes to exchange "payments" with routing key "payment.succeeded":
      """
      this is not an event
      """
    And "payments-queue" publishes json to exchange "payments" with routing key "payment.succeeded":
      """
      {"order_id": "order-7", "customer_email": "ada@example.com", "amount_cents": 250, "currency": "EUR"}
      """
    Then "notifications-db" query "SELECT status FROM notifications WHERE order_id = 'order-7'" returns within "10s":
      | status |
      | sent   |
    And "sendgrid-stub" received "1" requests
