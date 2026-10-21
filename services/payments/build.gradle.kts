plugins {
    kotlin("jvm") version "2.1.21"
    application
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.apache.kafka:kafka-clients:3.9.1")
    // MSK IAM authentication, with STS for the IRSA web identity credentials.
    implementation("software.amazon.msk:aws-msk-iam-auth:2.3.2")
    implementation("software.amazon.awssdk:sts:2.31.77")
    implementation("com.stripe:stripe-java:29.4.0")
    implementation("com.rabbitmq:amqp-client:5.25.0")
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin:2.19.2")
    implementation("org.slf4j:slf4j-simple:2.0.17")

    testImplementation(kotlin("test"))
}

kotlin {
    jvmToolchain(17)
}

application {
    mainClass.set("demo.payments.MainKt")
}

tasks.test {
    useJUnitPlatform()
}
