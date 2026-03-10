"""Binance !ticker@arr → Kafka producer

Connects to Binance's all-market ticker WebSocket stream and publishes
per-symbol ticker updates to the Kafka topic `crypto.ticker`.

Filters:
  - USDT pairs only
  - Minimum 24hr quote volume of $1M USDT (configurable via MIN_QUOTE_VOLUME)

Usage:
  pip install "lukewarm[streaming]"
  python producers/binance_ticker.py

Environment variables:
  KAFKA_BOOTSTRAP_SERVERS   default: localhost:9092
  MIN_QUOTE_VOLUME          default: 1_000_000 (USDT)
"""

import asyncio
import json
import logging
import os
import signal

import websockets
from kafka import KafkaProducer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

BINANCE_WS_URL = "wss://stream.binance.us:9443/ws/!ticker@arr"
KAFKA_TOPIC = "crypto.ticker"
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
MIN_QUOTE_VOLUME = float(os.getenv("MIN_QUOTE_VOLUME", "1_000_000"))
RECONNECT_DELAY_S = 5


def build_producer() -> KafkaProducer:
    return KafkaProducer(
        bootstrap_servers=KAFKA_BOOTSTRAP,
        key_serializer=str.encode,
        value_serializer=lambda v: json.dumps(v).encode(),
        acks="all",
        retries=3,
    )


def parse_ticker(raw: dict) -> dict | None:
    symbol: str = raw.get("s", "")
    if not symbol.endswith("USDT"):
        return None
    quote_volume = float(raw.get("q", 0))
    if quote_volume < MIN_QUOTE_VOLUME:
        return None
    return {
        "symbol": symbol,
        "last_price": float(raw["c"]),
        "price_change": float(raw["p"]),
        "price_change_pct": float(raw["P"]),
        "high_24h": float(raw["h"]),
        "low_24h": float(raw["l"]),
        "base_volume_24h": float(raw["v"]),
        "quote_volume_24h": quote_volume,
        "num_trades_24h": int(raw["n"]),
        "event_time_ms": int(raw["E"]),
    }


async def stream(producer: KafkaProducer, stop: asyncio.Event) -> None:
    while not stop.is_set():
        try:
            log.info("Connecting to Binance WebSocket...")
            async with websockets.connect(BINANCE_WS_URL, ping_interval=20) as ws:
                log.info("Connected. Streaming ticker data...")
                published = 0
                async for raw_message in ws:
                    if stop.is_set():
                        break
                    tickers = json.loads(raw_message)
                    for raw in tickers:
                        ticker = parse_ticker(raw)
                        if ticker is None:
                            continue
                        producer.send(
                            KAFKA_TOPIC,
                            key=ticker["symbol"],
                            value=ticker,
                        )
                        published += 1
                    if published and published % 500 == 0:
                        producer.flush()
                        log.info(f"Published {published} ticker events so far")

        except (websockets.ConnectionClosed, OSError) as exc:
            if stop.is_set():
                break
            log.warning(f"Connection lost ({exc}). Reconnecting in {RECONNECT_DELAY_S}s...")
            await asyncio.sleep(RECONNECT_DELAY_S)

    producer.flush()
    log.info("Producer shut down cleanly.")


async def main() -> None:
    producer = build_producer()
    stop = asyncio.Event()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)

    log.info(f"Kafka bootstrap: {KAFKA_BOOTSTRAP}")
    log.info(f"Topic:           {KAFKA_TOPIC}")
    log.info(f"Min quote vol:   ${MIN_QUOTE_VOLUME:,.0f} USDT")

    await stream(producer, stop)
    producer.close()


if __name__ == "__main__":
    asyncio.run(main())
