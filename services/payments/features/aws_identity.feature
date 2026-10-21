Feature: Signing in to MSK with the service's IAM role
  On AWS, payments reads orders from MSK and authenticates with IAM: its pod
  gets an IAM role through IRSA, and the MSK IAM library signs in with that
  role's session. tomato plays STS and an MSK IAM listener that admits only
  sessions of that role, so payments consuming at all proves the whole path.

  Scenario: payments signs in to Kafka as its own role
    Then "aws" role "arn:aws:iam::000000000000:role/payments" was assumed
    And "orders" consumer group "payments" is consuming "orders.created" within "60s"
    And "aws" role "arn:aws:iam::000000000000:role/orders" was not assumed
