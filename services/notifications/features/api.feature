Feature: Looking up notifications
  Support staff look up what a customer was told about an order.

  Scenario: The notifications of an order are listed
    Given "notifications-db" table "notifications" has values:
      | order_id | kind            | recipient       | subject                 | status |
      | order-1  | order_confirmed | ada@example.com | Your order is confirmed | sent   |
      | order-2  | payment_failed  | bob@example.com | We could not take your payment | sent |
    And "notifications-client" query param "order_id" is "order-1"
    When "notifications-client" sends "GET" to "/notifications"
    Then "notifications-client" response status is "200"
    And "notifications-client" response json "notifications[0].recipient" is email
    And "notifications-client" response json contains:
      """
      {"notifications": [{"order_id": "order-1", "kind": "order_confirmed", "status": "sent"}]}
      """
    And "notifications-client" response json "notifications[1]" does not exist

  Scenario: An order without notifications has none
    When "notifications-client" sends "GET" to "/notifications?order_id=order-404"
    Then "notifications-client" response status is "200"
    And "notifications-client" response json matches:
      """
      {"notifications": []}
      """
