from notifications.messages import email_for, price


def test_price():
    assert price(1199, "EUR") == "11.99 EUR"
    assert price(5, "EUR") == "0.05 EUR"


def test_confirmation():
    email = email_for("payment.succeeded", {
        "order_id": "o-1", "customer_email": "ada@example.com", "amount_cents": 1199, "currency": "EUR"})
    assert email.kind == "order_confirmed"
    assert email.to == "ada@example.com"
    assert "11.99 EUR" in email.text


def test_failure_explains_the_reason():
    email = email_for("payment.failed", {
        "order_id": "o-1", "customer_email": "ada@example.com", "amount_cents": 500, "reason": "card_declined"})
    assert email.subject == "We could not take your payment"
    assert email.text.endswith("your card was declined.")


def test_other_events_need_no_email():
    assert email_for("payment.refunded", {"order_id": "o-1"}) is None
