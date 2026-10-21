"""What notifications tells a customer about each payment event."""

from dataclasses import dataclass

KINDS = {
    "payment.succeeded": "order_confirmed",
    "payment.failed": "payment_failed",
}

REASONS = {
    "card_declined": "your card was declined",
    "insufficient_funds": "your card has insufficient funds",
    "provider_unavailable": "our payment provider could not be reached",
}


@dataclass(frozen=True)
class Email:
    kind: str
    to: str
    subject: str
    text: str


def price(cents: int, currency: str) -> str:
    return f"{cents // 100}.{cents % 100:02d} {currency}"


def email_for(routing_key: str, event: dict) -> Email | None:
    """The email to send for a payment event, or None for events that need none."""
    kind = KINDS.get(routing_key)
    if kind is None:
        return None
    order = event["order_id"]
    total = price(int(event.get("amount_cents", 0)), event.get("currency", "EUR"))
    if kind == "order_confirmed":
        return Email(kind, event["customer_email"], "Your order is confirmed",
                     f"Thank you! We received {total} for order {order}.")
    reason = REASONS.get(event.get("reason", ""), "the payment did not go through")
    return Email(kind, event["customer_email"], "We could not take your payment",
                 f"We could not charge {total} for order {order}: {reason}.")
