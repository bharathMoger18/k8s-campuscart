## ----Stage 1: Builder---------------

FROM python:3.12-slim AS builder 

## Install build dependencies gcc and libpq-dev needed to compile psycopg2 

RUN apt-get update && apt-get install -y --no-install-recommends gcc libpq-dev && rm -rf /var/lib/apt/lists/*

## Set working directory

WORKDIR /app

COPY requirements.txt . 

## Install all python packages into /install folder which can be copied to final stage 
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


## Stage 2 : Final 

FROM python:3.12-slim AS final 

## Install only runtime dependencies 
## libpq-dev: psycopg2 needs libpq at runtime to talk to postgres
## No gcc needed becuase compilation is done in Builder stage(1)

RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev netcat-openbsd curl && rm -rf /var/lib/apt/lists/*

## Create non root user , user run your application as root user

RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

## Set working directory 

WORKDIR /app

## Copy compiled python packeges from builder 

COPY --from=builder /install /usr/local

## Copy application code
COPY . .
## Copy frontend for serving via Django
COPY frontend_static /app/frontend

## Create directories django needs
## statisfiles: collectstatic output 
## media: user uploaded files

RUN mkdir -p /app/staticfiles /app/media /app/static

## give appuser ownership of everything

RUN chown -R appuser:appgroup /app

## Make entrypoint executable
RUN chmod +x /app/entrypoint.sh


## Switch to non-root user 

USER appuser

## Expose the Daphne port 

EXPOSE 8000

ENTRYPOINT ["/app/entrypoint.sh"]
