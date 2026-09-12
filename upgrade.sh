#!/usr/bin/env bash

set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

service="valheim"
backup_dir="backups"
backup_file="${backup_dir}/pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
service_stopped=false

restore_service_on_error() {
  exit_code=$?

  if [[ "$service_stopped" == true ]]; then
    echo "Upgrade failed; attempting to start ${service} again." >&2
    docker compose up -d "$service" || true
  fi

  exit "$exit_code"
}

trap restore_service_on_error ERR

command -v docker >/dev/null
command -v tar >/dev/null
docker compose config --quiet

if [[ ! -d data/config ]]; then
  echo "Cannot back up missing directory: data/config" >&2
  exit 1
fi

mkdir -p "$backup_dir"

if [[ -e "$backup_file" ]]; then
  echo "Backup already exists: ${backup_file}" >&2
  exit 1
fi

echo "Stopping ${service}..."
docker compose down
service_stopped=true

echo "Pulling the latest container image..."
docker compose pull "$service"

echo "Creating ${backup_file}..."
tar -czf "$backup_file" -C data config
tar -tzf "$backup_file" >/dev/null

echo "Downloading and validating the latest Valheim server from Steam..."
docker compose run --rm --no-deps \
  --entrypoint /opt/steamcmd/steamcmd.sh \
  "$service" \
  +force_install_dir /opt/valheim/dl/server \
  +login anonymous \
  +app_update 896660 validate \
  +quit

echo "Starting ${service}..."
docker compose up -d "$service"
service_stopped=false

trap - ERR
echo "Upgrade complete. Backup saved to ${backup_file}."
