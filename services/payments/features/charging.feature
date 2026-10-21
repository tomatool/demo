Feature: Charging for orders
  Every order announced on orders.created is charged with Stripe, and the
  outcome is published on the "payments" exchange.

  Background:
    Given "orders" consumer group "payments" is consuming "orders.created" within "60s"

  Scenario: An order is charged and its payment succeeds
    Given "mq" declares queue "outcomes.order-1"
    And "mq" binds queue "outcomes.order-1" to exchange "payments" with routing key "payment.*"
    And "stripe" stub "POST" "/v1/payment_intents" returns "200" with json:
      """
      {"id": "pi_1", "object": "payment_intent", "status": "succeeded", "amount": 1199, "currency": "eur"}
      """
    And "orders" message header "x-request-id" is "req-42"
    When "orders" publishes json to "orders.created" with key "order-1":
      """
      {"order_id": "order-1", "customer_email": "ada@example.com", "total_cents": 1199, "currency": "EUR",
       "stripe_customer_id": "cus_ada", "payment_method": "pm_ada_visa"}
      """
    Then "mq" receives from queue "outcomes.order-1" within "15s"
    And "mq" last message has routing key "payment.succeeded"
    And "mq" last message contains:
      """
      "order_id":"order-1","customer_email":"ada@example.com","amount_cents":1199
      """
    And "mq" last message contains:
      """
      "payment_id":"pi_1"
      """
    And "mq" last message has header "x-request-id" with value "req-42"

    # The PaymentIntent payments created, as Stripe's SDK sends it.
    And "stripe" received "POST" "/v1/payment_intents" "1" times
    And "stripe" received "POST" "/v1/payment_intents" with header "Authorization" "Bearer sk_test_tomato"
    And "stripe" received "POST" "/v1/payment_intents" with header "Idempotency-Key" "order-order-1"
    And "stripe" received request with body containing "amount=1199"
    And "stripe" received request with body containing "currency=eur"
    And "stripe" received request with body containing "customer=cus_ada"
    And "stripe" received request with body containing "payment_method=pm_ada_visa"
    And "stripe" received request with body containing "confirm=true"

  Scenario: A declined card fails the payment with Stripe's decline code
    Given "mq" declares queue "outcomes.order-2"
    And "mq" binds queue "outcomes.order-2" to exchange "payments" with routing key "payment.*"
    And "stripe" stub "POST" "/v1/payment_intents" returns "402" with json:
      """
      {"error": {"type": "card_error", "code": "card_declined", "decline_code": "insufficient_funds",
                 "message": "Your card has insufficient funds."}}
      """
    When "orders" publishes json to "orders.created" with key "order-2":
      """
      {"order_id": "order-2", "customer_email": "ada@example.com", "total_cents": 500, "currency": "EUR"}
      """
    Then "mq" receives from queue "outcomes.order-2" within "15s"
    And "mq" last message has routing key "payment.failed"
    And "mq" last message contains:
      """
      "reason":"insufficient_funds"
      """
    And "stripe" received "POST" "/v1/payment_intents" "1" times

  Scenario: Stripe failing for a moment is retried with the same idempotency key
    Given "mq" declares queue "outcomes.order-3"
    And "mq" binds queue "outcomes.order-3" to exchange "payments" with routing key "payment.*"
    And "stripe" stub "POST" "/v1/payment_intents" returns in sequence:
      | status | body                                                                         |
      | 503    | {"error": {"type": "api_error", "message": "try again"}}                     |
      | 503    | {"error": {"type": "api_error", "message": "try again"}}                     |
      | 200    | {"id": "pi_3", "object": "payment_intent", "status": "succeeded"}            |
    When "orders" publishes json to "orders.created" with key "order-3":
      """
      {"order_id": "order-3", "customer_email": "ada@example.com", "total_cents": 250, "currency": "EUR"}
      """
    Then "mq" receives from queue "outcomes.order-3" within "15s"
    And "mq" last message has routing key "payment.succeeded"
    And "stripe" received "POST" "/v1/payment_intents" "3" times
    And "stripe" received "POST" "/v1/payment_intents" with header "Idempotency-Key" "order-order-3"

  Scenario: Stripe staying unreachable fails the payment
    Given "mq" declares queue "outcomes.order-4"
    And "mq" binds queue "outcomes.order-4" to exchange "payments" with routing key "payment.*"
    And "stripe" refuses connections
    When "orders" publishes json to "orders.created" with key "order-4":
      """
      {"order_id": "order-4", "customer_email": "ada@example.com", "total_cents": 250, "currency": "EUR"}
      """
    Then "mq" receives from queue "outcomes.order-4" within "15s"
    And "mq" last message has routing key "payment.failed"
    And "mq" last message contains:
      """
      "reason":"provider_unavailable"
      """

  Scenario: An event payments cannot read does not hold up the orders behind it
    Given "mq" declares queue "outcomes.order-5"
    And "mq" binds queue "outcomes.order-5" to exchange "payments" with routing key "payment.*"
    And "stripe" stub "POST" "/v1/payment_intents" returns "200" with json:
      """
      {"id": "pi_5", "object": "payment_intent", "status": "succeeded"}
      """
    When "orders" publishes to "orders.created":
      """
      this is not an order
      """
    And "orders" publishes json to "orders.created" with key "order-5":
      """
      {"order_id": "order-5", "customer_email": "ada@example.com", "total_cents": 250, "currency": "EUR"}
      """
    Then "mq" receives from queue "outcomes.order-5" within "15s"
    And "mq" last message contains:
      """
      "order_id":"order-5"
      """
    And "mq" queue "outcomes.order-5" has "1" messages
    And "stripe" received "1" requests
