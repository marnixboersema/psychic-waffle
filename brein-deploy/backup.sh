#!/usr/bin/env bash
# Brein backup — cold tar of the open-webui-data volume. Designed for cron.
# Keeps the 4 most recent archives in /var/backups/brein/.
set -euo pipefail

BACKUP_DIR=${BACKUP_DIR:-/var/backups/brein}
COMPOSE_DIR=${COMPOSE_DIR:-/opt/brein}
VOLUME=${VOLUME:-open-webui-data}
KEEP=${KEEP:-4}

TS=$(date +%Y-%m-%d)
DEST="$BACKUP_DIR/brein-$TS.tar.gz"

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*"; }

mkdir -p "$BACKUP_DIR"
cd "$COMPOSE_DIR"

log "Stopping open-webui for cold backup"
docker compose stop open-webui

# Always restart the container, even if tar fails.
trap 'log "Restarting open-webui (trap)"; docker compose start open-webui || true' EXIT

log "Writing $DEST"
docker run --rm \
	-v "$VOLUME":/data:ro \
	-v "$BACKUP_DIR":/backup \
	alpine \
	tar czf "/backup/brein-$TS.tar.gz" -C / data

log "Restarting open-webui"
trap - EXIT
docker compose start open-webui

log "Pruning — keep last $KEEP"
ls -1t "$BACKUP_DIR"/brein-*.tar.gz 2>/dev/null \
	| tail -n +$((KEEP + 1)) \
	| xargs -r rm -v

log "Done. Current backups:"
ls -lh "$BACKUP_DIR"/brein-*.tar.gz 2>/dev/null || true
