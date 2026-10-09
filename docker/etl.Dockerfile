# Build context: the repository root; etl.Dockerfile.dockerignore admits only
# the two ETL checkouts under upstream/ and the files copied from docker/.
FROM python:3.11-slim@sha256:0dd364ba7e10242f07755449e3a3d0e35f9efd987952737b90def6709ab0c5ce

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DB_BACKEND=postgres \
    DATA_ROOT=/var/lib/etl \
    OUTPUT_DIR=/var/lib/etl/bronze \
    INPUT_DIR=/data/togo \
    PEFA_DIR=/data/pefa \
    COUNTRY_NAME=Togo \
    DDH_BOUNDARIES_DIR="/Volumes/prd_development_data/files/ddh/0038272/DR0095369/World Bank Official Boundaries (GeoJSON)"

COPY docker/etl-requirements.txt /tmp/etl-requirements.txt
RUN pip install --no-cache-dir -r /tmp/etl-requirements.txt \
    && useradd --create-home --uid 10002 etl \
    && install -d -o etl /var/lib/etl "$DDH_BOUNDARIES_DIR" \
    && chown -R etl /Volumes

COPY upstream/mega-indicators /opt/upstream/mega-indicators
COPY upstream/mega-boost /opt/upstream/mega-boost
COPY docker/etl-run.py /usr/local/bin/etl-run

USER etl
ENTRYPOINT ["etl-run"]
