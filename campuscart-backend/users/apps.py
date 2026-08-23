import os
import time
import threading
import logging

from django.apps import AppConfig

logger = logging.getLogger(__name__)

_collector_started = False


class UsersConfig(AppConfig):
    default_auto_field = 'django.db.models.BigAutoField'
    name = 'users'

    def ready(self):
        global _collector_started
        if _collector_started:
            return

        # Django's dev-server autoreloader calls ready() twice — once for the
        # watcher process, once for the real child that actually serves
        # requests. Only start the collector in the process that's really
        # running (RUN_MAIN unset entirely means production/Gunicorn/Daphne,
        # where this only runs once anyway).
        if os.environ.get("RUN_MAIN") in (None, "true"):
            _collector_started = True
            thread = threading.Thread(target=self._run_user_count_collector, daemon=True)
            thread.start()

    def _run_user_count_collector(self):
        from django.contrib.auth import get_user_model
        from .metrics import registered_users_total

        User = get_user_model()
        while True:
            try:
                registered_users_total.set(User.objects.count())
            except Exception:
                logger.exception("registered_users_total collector failed")
            time.sleep(60)
