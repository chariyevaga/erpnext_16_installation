#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/backups"
TIMESTAMP="$(date +%F_%H-%M-%S)"
FILENAME="mariadb_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "[backup] Starting backup at ${TIMESTAMP}"

mysqldump \
  -h "${DB_HOST}" \
  -P "${DB_PORT}" \
  -u "${DB_USER}" \
  -p"${DB_PASSWORD}" \
  --single-transaction \
  --routines \
  --events \
  --triggers \
  "${DB_NAME}" | gzip > "${BACKUP_DIR}/${FILENAME}"

echo "[backup] Completed: ${BACKUP_DIR}/${FILENAME}"
