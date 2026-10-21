package demo.payments

import com.fasterxml.jackson.module.kotlin.jacksonObjectMapper
import com.fasterxml.jackson.module.kotlin.readValue
import com.rabbitmq.client.AMQP
import com.rabbitmq.client.Channel
import com.rabbitmq.client.Connection
import com.rabbitmq.client.ConnectionFactory
import org.apache.kafka.clients.CommonClientConfigs
import org.apache.kafka.clients.admin.AdminClient
import org.apache.kafka.clients.admin.NewTopic
import org.apache.kafka.clients.consumer.ConsumerConfig
import org.apache.kafka.common.errors.TopicExistsException
import org.apache.kafka.clients.consumer.KafkaConsumer
import org.apache.kafka.common.config.SaslConfigs
import org.apache.kafka.common.errors.WakeupException
import org.apache.kafka.common.serialization.StringDeserializer
import org.slf4j.LoggerFactory
import java.time.Duration
import java.util.Properties

/**
 * kafkaSecurity is the client configuration for the brokers. With auth
 * "aws_msk_iam" the clients sign in to MSK with the AWS identity the default
 * credential chain finds: on EKS, the service's IAM role through IRSA.
 */
fun kafkaSecurity(brokers: String, auth: String): Map<String, Any> {
    val config = mutableMapOf<String, Any>(CommonClientConfigs.BOOTSTRAP_SERVERS_CONFIG to brokers)
    if (auth == "aws_msk_iam") {
        // SASL_SSL on MSK; KAFKA_SECURITY_PROTOCOL=SASL_PLAINTEXT for a local broker.
        config[CommonClientConfigs.SECURITY_PROTOCOL_CONFIG] = env("KAFKA_SECURITY_PROTOCOL", "SASL_SSL")
        config[SaslConfigs.SASL_MECHANISM] = "AWS_MSK_IAM"
        config[SaslConfigs.SASL_JAAS_CONFIG] = "software.amazon.msk.auth.iam.IAMLoginModule required;"
        config[SaslConfigs.SASL_CLIENT_CALLBACK_HANDLER_CLASS] = "software.amazon.msk.auth.iam.IAMClientCallbackHandler"
    }
    return config
}

/** OrderConsumer feeds every order on the topic to payments, one at a time. */
class OrderConsumer(private val kafka: Map<String, Any>, private val topic: String, private val payments: Payments) {
    private val log = LoggerFactory.getLogger(OrderConsumer::class.java)
    private val json = jacksonObjectMapper()
    private val consumer = KafkaConsumer<String, String>(
        Properties().apply {
            putAll(kafka)
            put(ConsumerConfig.GROUP_ID_CONFIG, "payments")
            put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest")
            put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false")
            put(ConsumerConfig.METADATA_MAX_AGE_CONFIG, "1000")
            put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer::class.java.name)
            put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer::class.java.name)
        },
    )

    @Volatile
    var running = false
        private set

    fun run() {
        ensureTopic()
        consumer.subscribe(listOf(topic))
        running = true
        try {
            while (true) {
                for (record in consumer.poll(Duration.ofMillis(250))) {
                    val requestId = record.headers().lastHeader("x-request-id")?.value()?.let { String(it) }
                    val order = try {
                        json.readValue<OrderCreated>(record.value())
                    } catch (e: Exception) {
                        // A message payments cannot read is skipped, not retried
                        // forever: it would block every order behind it.
                        log.warn("skipping unreadable order event at offset {}: {}", record.offset(), record.value())
                        continue
                    }
                    payments.handle(order, requestId)
                }
                consumer.commitSync()
            }
        } catch (e: WakeupException) {
            // stopping
        } finally {
            running = false
            consumer.close()
        }
    }

    fun stop() = consumer.wakeup()

    /** Creates the topic if it does not exist yet, so payments can start before orders. */
    private fun ensureTopic() {
        AdminClient.create(kafka).use { admin ->
            try {
                admin.createTopics(listOf(NewTopic(topic, 1, 1.toShort()))).all().get()
                log.info("created topic {}", topic)
            } catch (e: java.util.concurrent.ExecutionException) {
                if (e.cause !is TopicExistsException) throw e
            }
        }
    }
}

/** OutcomePublisher publishes payment outcomes on the "payments" exchange. */
class OutcomePublisher(url: String) : Publisher, AutoCloseable {
    private val json = jacksonObjectMapper()
    private val connection: Connection = connect(url)
    private val channel: Channel = connection.createChannel().apply {
        exchangeDeclare("payments", "topic", true)
    }

    val connected: Boolean get() = connection.isOpen && channel.isOpen

    @Synchronized
    override fun publish(outcome: Outcome, requestId: String?) {
        val props = AMQP.BasicProperties.Builder()
            .contentType("application/json")
            .deliveryMode(2)
            .headers(requestId?.let { mapOf("x-request-id" to it) } ?: emptyMap())
            .build()
        channel.basicPublish("payments", outcome.routingKey, props, json.writeValueAsBytes(outcome.body))
    }

    override fun close() = connection.close()

    private companion object {
        fun connect(url: String): Connection {
            val factory = ConnectionFactory().apply {
                setUri(url)
                isAutomaticRecoveryEnabled = true
            }
            var attempt = 0
            while (true) {
                try {
                    return factory.newConnection("payments")
                } catch (e: Exception) {
                    if (++attempt >= 120) throw e
                    Thread.sleep(1_000)
                }
            }
        }
    }
}
