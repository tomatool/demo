package demo.payments

import kotlin.test.Test
import kotlin.test.assertEquals

class PaymentsTest {
    private val order = OrderCreated("order-1", "ada@example.com", 1199, "EUR")

    @Test
    fun `a provider that recovers within the attempts is charged once it does`() {
        val results = ArrayDeque(listOf(ChargeResult.Unavailable, ChargeResult.Succeeded("ch_1")))
        val published = mutableListOf<Outcome>()
        Payments({ results.removeFirst() }, { o, _ -> published += o }, backoffMillis = 0).handle(order, null)

        assertEquals("payment.succeeded", published.single().routingKey)
        assertEquals("ch_1", published.single().body["payment_id"])
    }

    @Test
    fun `a provider that stays unavailable fails the payment`() {
        var calls = 0
        val published = mutableListOf<Outcome>()
        Payments({ calls++; ChargeResult.Unavailable }, { o, _ -> published += o }, backoffMillis = 0)
            .handle(order, null)

        assertEquals(3, calls)
        assertEquals("provider_unavailable", published.single().body["reason"])
    }
}
