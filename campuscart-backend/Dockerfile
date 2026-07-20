## =====================================================================
## Stage 1: Builder — compiles dependencies, never ships to production
## =====================================================================
FROM python:3.12-slim AS builder

## PYTHONDONTWRITEBYTECODE: don't write .pyc files — this is a build
## stage that gets discarded entirely, so cached bytecode here is
## pure waste.
## PYTHONUNBUFFERED: force stdout/stderr to be unbuffered. Without
## this, Python buffers output — meaning `docker logs` / kubectl logs
## can appear delayed or missing until the buffer flushes. Non-negotiable
## for any containerized app; you need to SEE what's happening in real time.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

## gcc + libpq-dev: needed here (and ONLY here) to compile psycopg2
## from source. These add ~200MB and a real compiler toolchain to
## whatever image they're installed in — which is exactly why they
## live in a stage we throw away, never in the final image.
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

## Copy ONLY requirements.txt first, before any app code. This is a
## deliberate layer-caching decision: Docker caches each instruction's
## result and reuses it if nothing above it changed. If we copied all
## the code first, editing a single .py file would invalidate the
## cache and force a full pip reinstall on every build. By copying
## just requirements.txt first, `pip install` is only re-run when
## dependencies actually change — this is the single most impactful
## Docker build-speed optimization for almost any language.
COPY requirements.txt .

## --prefix=/install: install packages into an isolated directory
## rather than the system site-packages. This makes the NEXT stage's
## job trivial — copy one folder, get every dependency, with nothing
## else from the builder (no compiler, no apt cache, no source tarballs).
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


## =====================================================================
## Stage 2: Final — this is what actually ships and runs in production
## =====================================================================
FROM python:3.12-slim AS final

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

## Runtime-only system packages:
## - libpq5:          the actual Postgres CLIENT LIBRARY psycopg2 links
##                     against at runtime. NOT libpq-dev — that's the
##                     development package (headers, pkg-config) needed
##                     only to COMPILE against libpq, which already
##                     happened in the builder stage. Shipping -dev
##                     packages in a runtime image is a common mistake:
##                     bigger image, larger attack surface, no benefit.
## - netcat-openbsd:   used by entrypoint.sh to wait for Postgres to
##                     accept connections before running migrations.
## - curl:             used by docker-compose's HEALTHCHECK to verify
##                     the app is actually serving requests, not just
##                     that the process exists.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq5 \
    netcat-openbsd \
    curl \
    && rm -rf /var/lib/apt/lists/*

## Create a dedicated, unprivileged user/group for running the app.
## --system: no login shell, no password, no home dir prompts — this
## is a service account, not a human user.
## Why this matters: containers run as root by default. If the app
## process is ever compromised (a bad dependency, an injection bug),
## root-inside-the-container is a meaningfully larger blast radius
## than a restricted user with no special privileges.
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

WORKDIR /app

## Copy the fully-installed Python packages from the builder stage.
## /usr/local is where Python looks for site-packages by default —
## this one COPY line is the entire "dependency installation" step
## for the final image; no pip, no compiler, no leftover cache.
COPY --from=builder /install /usr/local

## Copy application code. This comes AFTER dependency installation
## specifically so that editing your own .py files never invalidates
## the (expensive) dependency-install layer above — only this layer
## and below get rebuilt on a normal code change.
COPY . .
COPY frontend_static /app/frontend

## Runtime directories Django needs to write to:
## - staticfiles: collectstatic output (CSS/JS served by whitenoise)
## - media:       user-uploaded content (product images)
## - static:      source static files before collection
RUN mkdir -p /app/staticfiles /app/media /app/static

## Hand ownership of the whole app directory to the unprivileged user
## BEFORE switching to it — chown must happen while we still have root.
RUN chown -R appuser:appgroup /app

RUN chmod +x /app/entrypoint.sh

## Switch to the non-root user. Everything from this line down —
## including the actual running application — executes as appuser,
## never as root.
USER appuser

## Documents which port the app listens on. This is metadata only —
## it does NOT actually publish the port (that's docker-compose's
## `ports:` or Kubernetes' Service definition). Still worth including:
## it's how anyone reading this Dockerfile (or an image inspector)
## knows what to expect without reading the app code.
EXPOSE 8000

## ENTRYPOINT (not CMD): entrypoint.sh always runs when the container
## starts, and isn't silently overridden by a command passed at
## `docker run` — appropriate here since it handles migrations and
## bootstrapping that must always happen before Daphne starts.
ENTRYPOINT ["/app/entrypoint.sh"]