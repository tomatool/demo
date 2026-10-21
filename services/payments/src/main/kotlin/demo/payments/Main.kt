// payments charges every new order. It consumes orders.created from Kafka
// (on AWS: MSK, authenticated with the service's IAM role), charges the
// customer with Stripe, and publishes the outcome on the RabbitMQ exchange
// "payments" for orders and notifications.
package demo.payments

import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import kotlin.concurrent.thread

fun env(key: String, fallback: String): String = System.getenv(key)?.takeIf { it.isNotEmpty() } ?: fallback

fun main() {
    val stripe = StripeCharger(
        apiBase = env("STRIPE_API_BASE", "https://api.stripe.com"),
        apiKey = env("STRIPE_API_KEY", "sk_test_dev"),
    )
    val outcomes = OutcomePublisher(env("RABBITMQ_URL", "amqp://guest:guest@localhost:5672"))
    val consumer = OrderConsumer(
        kafka = kafkaSecurity(env("KAFKA_BROKERS", "localhost:9092"), env("KAFKA_AUTH", "none")),
        topic = env("KAFKA_TOPIC", "orders.created"),
        payments = Payments(stripe, outcomes),
    )

    val health = HttpServer.create(InetSocketAddress(env("PORT", "8081").toInt()), 0)
    health.createContext("/health") { exchange ->
        val ok = consumer.running && outcomes.connected
        val body = """{"status":"${if (ok) "ok" else "starting"}"}""".toByteArray()
        exchange.responseHeaders.add("Content-Type", "application/json")
        exchange.sendResponseHeaders(if (ok) 200 else 503, body.size.toLong())
        exchange.responseBody.use { it.write(body) }
    }
    health.start()

    val worker = thread(name = "orders-consumer") { consumer.run() }
    Runtime.getRuntime().addShutdownHook(thread(start = false) {
        consumer.stop()
        worker.join(5_000)
        outcomes.close()
        health.stop(0)
    })
    println("payments listening on :${health.address.port}")
}
