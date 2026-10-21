package demo.payments

import com.fasterxml.jackson.annotation.JsonIgnoreProperties
import com.fasterxml.jackson.annotation.JsonProperty
import org.slf4j.LoggerFactory

@JsonIgnoreProperties(ignoreUnknown = true)
data class OrderCreated(
    @JsonProperty("order_id") val orderId: String,
    @JsonProperty("customer_email") val customerEmail: String,
    @JsonProperty("total_cents") val totalCents: Long,
    @JsonProperty("currency") val currency: String,
    // The shop keeps each customer's card with Stripe; orders that do not say
    // which one use Stripe's test card.
    @JsonProperty("stripe_customer_id") val customerId: String? = null,
    @JsonProperty("payment_method") val paymentMethod: String = "pm_card_visa",
)

sealed interface ChargeResult {
    data class Succeeded(val paymentId: String) : ChargeResult
    data class Declined(val reason: String) : ChargeResult
    data object Unavailable : ChargeResult
}

/** The outcome of charging for one order, as published on RabbitMQ. */
data class Outcome(val routingKey: String, val body: Map<String, Any>)

/** Payments decides what charging an order leads to. */
class Payments(
    private val provider: Charger,
    private val outcomes: Publisher,
    private val attempts: Int = 3,
    private val backoffMillis: Long = 200,
) {
    private val log = LoggerFactory.getLogger(Payments::class.java)

    fun handle(order: OrderCreated, requestId: String?) {
        val outcome = outcomeOf(order, charge(order))
        outcomes.publish(outcome, requestId)
        log.info("order {} {} (request {})", order.orderId, outcome.routingKey, requestId)
    }

    /** Charges the order, retrying while the provider is unavailable. */
    private fun charge(order: OrderCreated): ChargeResult {
        repeat(attempts) { attempt ->
            val result = provider.charge(order)
            if (result != ChargeResult.Unavailable) return result
            if (attempt < attempts - 1) Thread.sleep(backoffMillis * (attempt + 1))
        }
        return ChargeResult.Unavailable
    }

    companion object {
        fun outcomeOf(order: OrderCreated, result: ChargeResult): Outcome {
            val common = mapOf(
                "order_id" to order.orderId,
                "customer_email" to order.customerEmail,
                "amount_cents" to order.totalCents,
                "currency" to order.currency,
            )
            return when (result) {
                is ChargeResult.Succeeded ->
                    Outcome("payment.succeeded", common + ("payment_id" to result.paymentId))
                is ChargeResult.Declined ->
                    Outcome("payment.failed", common + ("reason" to result.reason))
                ChargeResult.Unavailable ->
                    Outcome("payment.failed", common + ("reason" to "provider_unavailable"))
            }
        }
    }
}

fun interface Charger {
    fun charge(order: OrderCreated): ChargeResult
}

fun interface Publisher {
    fun publish(outcome: Outcome, requestId: String?)
}
