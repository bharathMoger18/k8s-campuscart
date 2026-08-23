from prometheus_client import Gauge

chat_active_connections = Gauge(
    "chat_active_connections",
    "Number of currently open WebSocket chat connections",
)
