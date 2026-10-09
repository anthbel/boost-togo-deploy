# Build context: upstream/rpf-country-dash (scripts/fetch-upstream.sh).
FROM python:3.11-slim@sha256:0dd364ba7e10242f07755449e3a3d0e35f9efd987952737b90def6709ab0c5ce

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    QUERY_CACHE_DIR=/var/cache/dash/queries

RUN useradd --create-home --uid 10001 dash \
    && mkdir -p /var/cache/dash/queries \
    && chown -R dash /var/cache/dash

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

USER dash
EXPOSE 8080
# Worker count and timeouts are tuned through GUNICORN_CMD_ARGS.
CMD ["gunicorn", "-b", "0.0.0.0:8080", "app:server"]
