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

echo "Creating superuser if not exists..."
python manage.py shell -c "
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(email='admin@campuscart.com').exists():
    User.objects.create_superuser(email='admin@campuscart.com', password='Admin@1234', name='Admin')
    print('Superuser created')
else:
    print('Superuser already exists')
"

echo "Starting Daphne..."
exec daphne -b 0.0.0.0 -p 8000 campuscart.asgi:application
