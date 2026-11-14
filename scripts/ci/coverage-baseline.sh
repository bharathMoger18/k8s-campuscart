#!/usr/bin/env bash
# Runs the backend tests the way the Jenkins Test stage does, with coverage, using throwaway local containers.
# No AWS, and nothing is written to the repo: the source is copied INSIDE the container, without venv or .env.
set -uo pipefail
cd "$(dirname "$0")/../.."
NET=cc-test-net
cleanup() { docker rm -f cc-pg cc-redis >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null
docker run -d --name cc-pg --network "$NET" -e POSTGRES_DB=test_campuscart_db -e POSTGRES_USER=test_user \
  -e POSTGRES_PASSWORD=test_pass postgres:15.20-alpine >/dev/null
docker run -d --name cc-redis --network "$NET" redis:7.4.12-alpine >/dev/null
docker run --rm --network "$NET" -v "$PWD/campuscart-backend":/src:ro \
  -e DB_HOST=cc-pg -e DB_PORT=5432 -e DB_NAME=test_campuscart_db -e DB_USER=test_user -e DB_PASSWORD=test_pass \
  -e REDIS_HOST=cc-redis -e REDIS_PORT=6379 -e DJANGO_SECRET_KEY=ci-test-only-not-a-real-secret-00000000 \
  -e DEBUG=True -e ALLOWED_HOSTS=localhost,127.0.0.1 \
  python:3.12.16-slim sh -c '
    set -e
    mkdir /app && cd /src && tar --exclude=venv --exclude=.env --exclude="*.env" --exclude=__pycache__ -cf - . | tar -C /app -xf -
    cd /app
    apt-get update -qq && apt-get install -y -qq netcat-openbsd >/dev/null
    until nc -z cc-pg 5432; do sleep 2; done
    until nc -z cc-redis 6379; do sleep 2; done
    pip install -q --no-cache-dir --disable-pip-version-check --root-user-action=ignore -r requirements.txt coverage
    coverage --version | head -1
    set +e
    coverage run --source=. --omit="*/migrations/*,*/tests.py,*/tests/*,*/test_*.py,manage.py" manage.py test --noinput
    echo "test exit code: $?"
    coverage report --skip-empty | tail -45
  '
