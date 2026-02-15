#!/usr/bin/env bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
SITE_NAME="${SITE_NAME:-site1.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-change_me}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-change_me}"
DB_HOST="${DB_HOST:-mariadb}"
DB_PORT="${DB_PORT:-3306}"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_CACHE="${REDIS_CACHE:-redis://${REDIS_HOST}:${REDIS_PORT}/0}"
REDIS_QUEUE="${REDIS_QUEUE:-redis://${REDIS_HOST}:${REDIS_PORT}/1}"
REDIS_SOCKETIO="${REDIS_SOCKETIO:-redis://${REDIS_HOST}:${REDIS_PORT}/2}"
SOCKETIO_PORT="${SOCKETIO_PORT:-9000}"

cd "$BENCH_DIR"

# Ensure apps.txt exists (volume mount can hide the default symlink)
if [ ! -f "sites/apps.txt" ]; then
  printf "frappe\nerpnext\n" > "sites/apps.txt"
fi
if [ ! -f "apps.txt" ]; then
  ln -s "sites/apps.txt" "apps.txt"
fi
if [ ! -f "sites/common_site_config.json" ]; then
  echo "{}" > "sites/common_site_config.json"
fi
if [ ! -f "Procfile" ]; then
  cat > "Procfile" <<'PROCFILE'
web: bench serve --port 8000
socketio: node apps/frappe/socketio.js
schedule: bench schedule
worker: bench worker
PROCFILE
fi

# Ensure apps.txt includes all apps present in bench
for app in $(ls -1 apps); do
  if ! grep -q -x "$app" "sites/apps.txt"; then
    echo "$app" >> "sites/apps.txt"
  fi
done

# Wait for MariaDB
until mysqladmin ping -h"$DB_HOST" -P"$DB_PORT" --silent; do
  echo "Waiting for MariaDB at $DB_HOST:$DB_PORT..."
  sleep 2
done

# Wait for Redis
until redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; do
  echo "Waiting for Redis..."
  sleep 2
done

# Global configs
bench set-config -g db_host "$DB_HOST"
bench set-config -g db_port "$DB_PORT"
bench set-config -g redis_cache "$REDIS_CACHE"
bench set-config -g redis_queue "$REDIS_QUEUE"
bench set-config -g redis_socketio "$REDIS_SOCKETIO"
bench set-config -g socketio_port "$SOCKETIO_PORT"

# Create site if it doesn't exist
if [ ! -f "sites/$SITE_NAME/site_config.json" ]; then
  echo "Creating new site: $SITE_NAME"
  bench new-site "$SITE_NAME" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --install-app erpnext \
    --set-default
else
  echo "Site already exists: $SITE_NAME"
fi

# Ensure schema is up to date before installing custom apps
bench --site "$SITE_NAME" migrate

# Install any custom apps already present in apps/
installed_apps="$(bench --site "$SITE_NAME" list-apps | tr -d '\r')"
for app in $(ls -1 apps); do
  if [ "$app" != "frappe" ] && [ "$app" != "erpnext" ]; then
    if ! echo "$installed_apps" | grep -q -x "$app"; then
      bench --site "$SITE_NAME" install-app "$app" || true
    fi
  fi
done

# Start bench (web + workers + scheduler + socketio)
exec bench start
