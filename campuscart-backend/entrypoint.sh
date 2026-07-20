#!/bin/sh

# Only wait for DB if DB_HOST is explicitly set (local Docker)
if [ -n "$DB_HOST" ] && [ -n "$DB_PORT" ]; then
    echo "Waiting for PostgreSQL at $DB_HOST:$DB_PORT..."
    while ! nc -z $DB_HOST $DB_PORT; do
        sleep 1
    done
    echo "PostgreSQL is ready."
else
    echo "Using DATABASE_URL directly, skipping DB wait..."
fi

echo "Running migrations..."
python manage.py migrate --noinput

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