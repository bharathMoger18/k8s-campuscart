#!/bin/sh
set -e

# --- Vault Agent Injector: load secrets rendered by the init container ---
# Kubernetes guarantees every init container completes before the main
# container starts, and the injector's init container is what writes
# this file — so by the time we're here, it already exists. No wait
# loop needed here, unlike the Postgres check below, which waits on a
# SEPARATE pod that genuinely might not be ready yet.
#
# Kept optional (not a hard failure if missing) so this same script
# still works for local Docker / docker-compose, where there's no
# Vault and secrets come from a plain .env file or envFrom instead.
VAULT_SECRETS_FILE="/vault/secrets/campuscart.env"
if [ -f "$VAULT_SECRETS_FILE" ]; then
    echo "Loading secrets from Vault-rendered file..."
    set -a
    . "$VAULT_SECRETS_FILE"
    set +a
else
    echo "No Vault-rendered secrets file found — using existing environment."
fi

if [ -n "$DB_HOST" ] && [ -n "$DB_PORT" ]; then
    echo "Waiting for PostgreSQL at $DB_HOST:$DB_PORT..."
    until nc -z "$DB_HOST" "$DB_PORT"; do
        sleep 1
    done
    echo "PostgreSQL is ready."
else
    echo "Using DATABASE_URL directly, skipping DB wait..."
fi

echo "Running migrations..."
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

echo "Starting Daphne..."
exec daphne -b 0.0.0.0 -p 8000 campuscart.asgi:application