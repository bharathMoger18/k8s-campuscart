from prometheus_client import Counter, Gauge

user_registrations_total = Counter(
    "user_registrations_total",
    "Total user registration attempts, labeled by outcome",
    ["status"],
)

user_logins_total = Counter(
    "user_logins_total",
    "Total login attempts, labeled by result",
    ["result"],
)

registered_users_total = Gauge(
    "registered_users_total",
    "Current total number of registered users",
)
