#!/bin/sh
set -e

# --- Vault Agent Injector: load static secrets rendered by init container ---
# Kubernetes guarantees every init container completes before the main
# container starts, so this file already exists by the time we get here.
# Optional (not a hard failure) so local Docker/dev without Vault still works.
VAULT_SECRETS_FILE="/vault/secrets/campuscart.env"
if [ -f "$VAULT_SECRETS_FILE" ]; then
    echo "Loading secrets from Vault-rendered file..."
    set -a
    . "$VAULT_SECRETS_FILE"
    set +a
else
    echo "No Vault-rendered secrets file found — using existing environment."
fi

# NOTE: DB_USER / DB_PASSWORD are deliberately NOT sourced as env vars
# here. The custom database backend (campuscart.db_backend) reads
# /vault/secrets/db-creds.env directly, fresh, on every new connection —
# for "web" pods that's the DYNAMIC, DML-only role; for the migration
# Job (MIGRATE_ONLY=true below) it's the STATIC campuscart_user
# credential, rendered from a different Vault path via that Job's own
# annotations. Same filename, same format, different Vault source per
# workload — the backend code doesn't need to know which.

if [ -n "$DB_HOST" ] && [ -n "$DB_PORT" ]; then
    echo "Waiting for PostgreSQL at $DB_HOST:$DB_PORT..."
    until nc -z "$DB_HOST" "$DB_PORT"; do
        sleep 1
    done
    echo "PostgreSQL is ready."
else
    echo "Using DATABASE_URL directly, skipping DB wait..."
fi

# --- Migration Job path ---
# Only the migration Job sets MIGRATE_ONLY=true. It has its own
# db-creds.env pointing at campuscart_user's static, DDL-capable
# credential (not the dynamic app role), so it's the only place
# migrate/collectstatic/superuser-bootstrap ever run. A normal "web"
# pod boot skips this whole block entirely and goes straight to Daphne.
if [ "$MIGRATE_ONLY" = "true" ]; then
    echo "MIGRATE_ONLY set — running migrations for this deploy..."
    i=0
    until python manage.py migrate --noinput; do
        i=$((i + 1))
        if [ "$i" -ge 5 ]; then
            echo "Migrations failed after 5 attempts. Exiting."
            exit 1
        fi
        echo "Migration attempt $i failed — retrying in 3s..."
        sleep 3
    done

    echo "Collecting static files..."
    python manage.py collectstatic --noinput

    echo "Checking for optional superuser bootstrap..."
    if [ -n "$DJANGO_SUPERUSER_EMAIL" ] && [ -n "$DJANGO_SUPERUSER_PASSWORD" ]; then
        python manage.py shell -c "
from django.contrib.auth import get_user_model
import os
User = get_user_model()
email = os.environ['DJANGO_SUPERUSER_EMAIL']
password = os.environ['DJANGO_SUPERUSER_PASSWORD']
name = os.environ.get('DJANGO_SUPERUSER_NAME', 'Admin')
if not User.objects.filter(email=email).exists():
    User.objects.create_superuser(email=email, password=password, name=name)
    print(f'Superuser {email} created')
else:
    print(f'Superuser {email} already exists')
"
    else
        echo "DJANGO_SUPERUSER_EMAIL/PASSWORD not set — skipping superuser bootstrap."
    fi

    echo "Migration Job complete."
    exit 0
fi

echo "Starting Daphne..."
exec daphne -b 0.0.0.0 -p 8000 campuscart.asgi:application