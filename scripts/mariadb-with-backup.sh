#!/usr/bin/env bash
set -euo pipefail

crontab /etc/cron.d/mariadb-backup
touch /var/log/backup.log
cron

exec docker-entrypoint.sh "$@"
