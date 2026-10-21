package demo.payments

import com.stripe.Stripe
import com.stripe.exception.ApiConnectionException
import com.stripe.exception.CardException
import com.stripe.exception.StripeException
import com.stripe.model.PaymentIntent
import com.stripe.net.RequestOptions
import com.stripe.param.PaymentIntentCreateParams

/**
 * StripeCharger charges orders with Stripe, through Stripe's own Java SDK.
 * The API base is configurable so tests can point it at a stand-in.
 */
class StripeCharger(apiBase: String, private val apiKey: String) : Charger {
    init {
        Stripe.overrideApiBase(apiBase)
        // payments retries an unavailable Stripe itself, see Payments.
        Stripe.setMaxNetworkRetries(0)
    }

    override fun charge(order: OrderCreated): ChargeResult {
        val params = PaymentIntentCreateParams.builder()
            .setAmount(order.totalCents)
            .setCurrency(order.currency.lowercase())
            .setCustomer(order.customerId)
            .setPaymentMethod(order.paymentMethod)
            .setConfirm(true)
            .setOffSession(true)
            .setReceiptEmail(order.customerEmail)
            .putMetadata("order_id", order.orderId)
            .build()
        val options = RequestOptions.builder()
            .setApiKey(apiKey)
            // The order id makes a retried charge safe: Stripe charges once.
            .setIdempotencyKey("order-${order.orderId}")
            .build()

        return try {
            val intent = PaymentIntent.create(params, options)
            if (intent.status == "succeeded") ChargeResult.Succeeded(intent.id)
            else ChargeResult.Declined(intent.status)
        } catch (e: CardException) {
            ChargeResult.Declined(e.declineCode ?: e.code ?: "card_declined")
        } catch (e: ApiConnectionException) {
            ChargeResult.Unavailable
        } catch (e: StripeException) {
            if ((e.statusCode ?: 0) >= 500) ChargeResult.Unavailable
            else ChargeResult.Declined("stripe_rejected_${e.statusCode}")
        }
    }
}
