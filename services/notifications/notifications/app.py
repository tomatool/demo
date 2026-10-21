"""notifications emails customers about their payments.

It consumes the events payments publishes on the RabbitMQ exchange "payments"
and, for each order and event, once:

- emails the customer through SendGrid's v3 Mail Send API,
- archives the email in S3,
- tells the team's Slack channel when a payment failed,

and records the notification in Postgres. The record makes a redelivered event
harmless: an order is never emailed twice about the same thing.
"""

import asyncio
import json
import logging
import os
import signal

import aio_pika
import aiohttp
import asyncpg
import boto3
from aiohttp import web

from notifications.messages import Email, email_for

log = logging.getLogger("notifications")

MIGRATION = """
CREATE TABLE IF NOT EXISTS notifications (
    order_id   text        NOT NULL,
    kind       text        NOT NULL,
    recipient  text        NOT NULL,
    subject    text        NOT NULL,
    status     text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (order_id, kind)
);
"""


class SendGrid:
    """Sends email with SendGrid's v3 Mail Send API, retrying its outages."""

    def __init__(self, session: aiohttp.ClientSession, api_base: str, api_key: str, attempts: int = 3):
        self.session, self.api_base, self.api_key, self.attempts = session, api_base, api_key, attempts

    async def send(self, email: Email, request_id: str | None) -> str:
        headers = {"Authorization": f"Bearer {self.api_key}"}
        if request_id:
            headers["X-Request-Id"] = request_id
        body = {
            "personalizations": [{"to": [{"email": email.to}]}],
            "from": {"email": "shop@example.com", "name": "Tomato Shop"},
            "subject": email.subject,
            "content": [{"type": "text/plain", "value": email.text}],
            "categories": [email.kind],
        }
        for attempt in range(1, self.attempts + 1):
            try:
                async with self.session.post(f"{self.api_base}/v3/mail/send", json=body, headers=headers,
                                             timeout=aiohttp.ClientTimeout(total=5)) as resp:
                    if resp.status < 300:
                        return "sent"
                    if resp.status < 500:
                        log.warning("SendGrid refused the email to %s: %s", email.to, resp.status)
                        return "rejected"
            except aiohttp.ClientError as err:
                log.warning("SendGrid unreachable: %s", err)
            if attempt < self.attempts:
                await asyncio.sleep(0.2 * attempt)
        return "failed"


class Slack:
    """Posts to a Slack channel through an incoming webhook."""

    def __init__(self, session: aiohttp.ClientSession, webhook_url: str | None):
        self.session, self.webhook_url = session, webhook_url

    async def post(self, text: str) -> None:
        if not self.webhook_url:
            return
        try:
            async with self.session.post(self.webhook_url, json={"text": text},
                                         timeout=aiohttp.ClientTimeout(total=5)) as resp:
                if resp.status >= 300:
                    log.warning("Slack refused the alert: %s", resp.status)
        except aiohttp.ClientError as err:
            log.warning("Slack unreachable: %s", err)


class Archive:
    """Keeps a copy of every email in an S3 bucket, at <order_id>/<kind>.json."""

    def __init__(self, bucket: str):
        # The client finds its endpoint (AWS_ENDPOINT_URL_S3), region and
        # credentials the usual way, so the same code runs on AWS and on MinIO.
        self.s3, self.bucket = boto3.client("s3"), bucket

    async def put(self, order_id: str, email: Email, status: str) -> None:
        body = json.dumps({"to": email.to, "subject": email.subject, "text": email.text, "status": status})
        await asyncio.to_thread(self.s3.put_object, Bucket=self.bucket, Key=f"{order_id}/{email.kind}.json",
                                Body=body.encode(), ContentType="application/json")


class Notifier:
    def __init__(self, db: asyncpg.Pool, sendgrid: SendGrid, slack: Slack, archive: Archive):
        self.db, self.sendgrid, self.slack, self.archive = db, sendgrid, slack, archive

    async def handle(self, message: aio_pika.abc.AbstractIncomingMessage) -> None:
        try:
            event = json.loads(message.body)
            email = email_for(message.routing_key, event)
        except (ValueError, KeyError, TypeError):
            log.warning("dropping unreadable event %s: %r", message.routing_key, message.body[:200])
            await message.reject(requeue=False)
            return
        if email is None:
            await message.ack()
            return

        order_id = event["order_id"]
        # Claim the notification before sending, so a redelivered event finds
        # it claimed and is not emailed again.
        claimed = await self.db.execute(
            """INSERT INTO notifications (order_id, kind, recipient, subject, status)
               VALUES ($1, $2, $3, $4, 'sending') ON CONFLICT DO NOTHING""",
            order_id, email.kind, email.to, email.subject)
        if claimed == "INSERT 0 0":
            log.info("already notified order %s about %s", order_id, email.kind)
            await message.ack()
            return

        request_id = (message.headers or {}).get("x-request-id")
        status = await self.sendgrid.send(email, request_id)
        await self.archive.put(order_id, email, status)
        if email.kind == "payment_failed":
            await self.slack.post(
                f":warning: Payment failed for order {order_id} ({email.to}): "
                f"{event.get('reason', 'unknown reason')}")
        await self.db.execute(
            "UPDATE notifications SET status = $3 WHERE order_id = $1 AND kind = $2",
            order_id, email.kind, status)
        log.info("order %s: %s email %s", order_id, email.kind, status)
        await message.ack()


async def consume(url: str, notifier: Notifier) -> aio_pika.abc.AbstractRobustConnection:
    for attempt in range(120):
        try:
            connection = await aio_pika.connect_robust(url)
            break
        except (OSError, aio_pika.exceptions.AMQPConnectionError):
            await asyncio.sleep(1)
    else:
        raise RuntimeError("RabbitMQ is unreachable")
    channel = await connection.channel()
    await channel.set_qos(prefetch_count=1)
    exchange = await channel.declare_exchange("payments", aio_pika.ExchangeType.TOPIC, durable=True)
    queue = await channel.declare_queue("notifications.payments", durable=True)
    await queue.bind(exchange, "payment.*")
    await queue.consume(notifier.handle)
    log.info("consuming payment events from %s", queue.name)
    return connection


def routes(db: asyncpg.Pool) -> web.Application:
    async def health(_: web.Request) -> web.Response:
        await db.fetchval("SELECT 1")
        return web.json_response({"status": "ok"})

    async def notifications(request: web.Request) -> web.Response:
        rows = await db.fetch(
            """SELECT order_id, kind, recipient, subject, status FROM notifications
               WHERE order_id = $1 ORDER BY created_at""",
            request.query.get("order_id", ""))
        return web.json_response({"notifications": [dict(r) for r in rows]})

    app = web.Application()
    app.router.add_get("/health", health)
    app.router.add_get("/notifications", notifications)
    return app


async def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    env = os.environ.get
    db = await asyncpg.create_pool(env("DATABASE_URL", "postgres://notifications:notifications@localhost:5432/notifications"))
    await db.execute(MIGRATION)

    async with aiohttp.ClientSession() as session:
        notifier = Notifier(
            db,
            SendGrid(session, env("SENDGRID_API_BASE", "https://api.sendgrid.com"), env("SENDGRID_API_KEY", "")),
            Slack(session, env("SLACK_WEBHOOK_URL")),
            Archive(env("ARCHIVE_BUCKET", "email-archive")),
        )
        connection = await consume(env("RABBITMQ_URL", "amqp://guest:guest@localhost:5672/"), notifier)

        runner = web.AppRunner(routes(db))
        await runner.setup()
        port = int(env("PORT", "8082"))
        await web.TCPSite(runner, "0.0.0.0", port).start()
        log.info("notifications listening on :%d", port)

        stop = asyncio.Event()
        for sig in (signal.SIGINT, signal.SIGTERM):
            asyncio.get_running_loop().add_signal_handler(sig, stop.set)
        await stop.wait()
        await runner.cleanup()
        await connection.close()
    await db.close()
