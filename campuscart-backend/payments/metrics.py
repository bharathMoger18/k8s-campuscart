from prometheus_client import Counter

payment_webhook_events_total = Counter(
    "payment_webhook_events_total",
    "Total payment webhook events received, labeled by event type and result",
    ["event_type", "result"],
)

payment_amount_captured_total = Counter(
    "payment_amount_captured_total",
    "Total amount successfully captured via payments",
)
