# campuscart-backend/campuscart/db_backend/base.py
#
# A thin subclass of Django's own postgresql backend. The ONLY thing
# this changes is where "user" and "password" come from when opening a
# NEW connection — everything else (host, port, database name, OPTIONS,
# connection pooling behavior) is inherited unchanged from Django's real
# implementation via super().
#
# WHY override get_connection_params() specifically: this is the one
# method Django calls every time it's about to open a connection and
# doesn't already have one. Since this project's DATABASES has no
# CONN_MAX_AGE set, Django closes the connection after most requests by
# default — so this method runs fresh often, not just once at process
# startup. That's what makes credential rotation actually take effect
# on a running pod, not just on the next restart.
import os

from django.db.backends.postgresql import base as postgresql_base

# Where the Vault Agent Injector renders the dynamic database/creds/
# campuscart-app secret. Kept separate from campuscart.env (the static
# secrets file) deliberately — this one's contents genuinely change at
# runtime when Vault rotates the lease; that one never does.
VAULT_DB_CREDS_FILE = "/vault/secrets/db-creds.env"


def _read_vault_db_creds():
    """
    Read DB_USER / DB_PASSWORD directly from the Vault-rendered file,
    fresh, on every call — no caching. Returns (None, None) if the file
    doesn't exist, which is the normal case for local Docker / dev,
    where there's no Vault sidecar and DATABASES falls back to plain
    env vars exactly as it always has.
    """
    if not os.path.exists(VAULT_DB_CREDS_FILE):
        return None, None

    creds = {}
    with open(VAULT_DB_CREDS_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or "=" not in line:
                continue
            key, _, value = line.partition("=")
            creds[key] = value

    return creds.get("DB_USER"), creds.get("DB_PASSWORD")


class DatabaseWrapper(postgresql_base.DatabaseWrapper):
    def get_connection_params(self):
        # Get Django's normal connection params first — host, port,
        # database name, OPTIONS, and whatever fallback USER/PASSWORD
        # came from settings.py's os.getenv() calls. We only touch
        # user/password below; everything else stays exactly as Django
        # would have built it.
        conn_params = super().get_connection_params()

        vault_user, vault_password = _read_vault_db_creds()
        if vault_user and vault_password:
            conn_params["user"] = vault_user
            conn_params["password"] = vault_password
        # else: no Vault file present — conn_params already has
        # whatever super() put there from settings.py's env-var
        # fallback, so local Docker/dev behaves exactly as before.

        return conn_params