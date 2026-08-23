from prometheus_client import Counter, Histogram

orders_created_total = Counter(
    "orders_created_total",
    "Total number of orders created, labeled by outcome",
    ["status"],
)

order_processing_duration_seconds = Histogram(
    "order_processing_duration_seconds",
    "Time taken to process an order from creation to completion",
)
