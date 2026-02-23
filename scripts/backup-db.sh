#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/backups"
TIMESTAMP="$(date +%F_%H-%M-%S)"
FILENAME="mariadb_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "[backup] Starting backup at ${TIMESTAMP}"

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-3306}"
DB_NAME="${DB_NAME:-${MYSQL_DATABASE:-}}"
DB_USER="${DB_USER:-${MYSQL_USER:-}}"
DB_PASSWORD="${DB_PASSWORD:-${MYSQL_PASSWORD:-}}"

if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
  # Cron jobs often don't inherit container env; try to read from PID 1.
  if [ -r /proc/1/environ ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        DB_NAME|DB_USER|DB_PASSWORD|MYSQL_DATABASE|MYSQL_USER|MYSQL_PASSWORD)
          export "$key"="$value"
          ;;
      esac
    done < <(tr '\0' '\n' < /proc/1/environ)

    DB_NAME="${DB_NAME:-${MYSQL_DATABASE:-}}"
    DB_USER="${DB_USER:-${MYSQL_USER:-}}"
    DB_PASSWORD="${DB_PASSWORD:-${MYSQL_PASSWORD:-}}"
  fi
fi

if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ] || [ -z "$DB_PASSWORD" ]; then
  echo "[backup] Missing DB credentials (DB_NAME/DB_USER/DB_PASSWORD or MYSQL_* env)."
  exit 1
fi

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

# Prune backups older than 10 days
find "$BACKUP_DIR" -type f -name "mariadb_*.sql.gz" -mtime +10 -print -delete

# Keep at most 100 newest backups
mapfile -t backups < <(ls -1t "$BACKUP_DIR"/mariadb_*.sql.gz 2>/dev/null || true)
if [ "${#backups[@]}" -gt 100 ]; then
  printf "%s\n" "${backups[@]:100}" | xargs -r rm -f
fi
