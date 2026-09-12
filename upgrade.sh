#!/usr/bin/env bash

set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

service="valheim"
backup_dir="backups"
upgrade_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_file="${backup_dir}/pre-upgrade-${upgrade_timestamp}.tar.gz"
steam_download_dir="/opt/valheim/dl/server"
steam_download_backup="/opt/valheim/dl/server.pre-upgrade-${upgrade_timestamp}"
service_stopped=false

download_valheim() {
  docker compose run --rm --no-deps \
    --entrypoint /opt/steamcmd/steamcmd.sh \
    "$service" \
    +force_install_dir /opt/valheim/dl/server \
    +login anonymous \
    +app_update 896660 validate \
    +quit
}

prepare_clean_steam_download() {
  docker compose run --rm --no-deps \
    --entrypoint /bin/sh \
    "$service" \
    -c 'set -eu
      download_dir=$1
      download_backup=$2

      if [ -e "$download_backup" ]; then
        echo "Steam download backup already exists: $download_backup" >&2
        exit 1
      fi

      if [ -e "$download_dir" ]; then
        mv -- "$download_dir" "$download_backup"
      fi

      mkdir -p "$download_dir"' \
    sh "$steam_download_dir" "$steam_download_backup"
}

restore_steam_download() {
  docker compose run --rm --no-deps \
    --entrypoint /bin/sh \
    "$service" \
    -c 'set -eu
      download_dir=$1
      download_backup=$2

      rm -rf -- "$download_dir"
      if [ -e "$download_backup" ]; then
        mv -- "$download_backup" "$download_dir"
      fi' \
    sh "$steam_download_dir" "$steam_download_backup"
}

remove_steam_download_backup() {
  docker compose run --rm --no-deps \
    --entrypoint /bin/sh \
    "$service" \
    -c 'rm -rf -- "$1"' \
    sh "$steam_download_backup"
}

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

echo "Moving the existing Steam download cache aside..."
prepare_clean_steam_download

echo "Downloading and validating a fresh Valheim server from Steam..."
if ! download_valheim; then
  echo "SteamCMD failed; restoring the previous Steam download cache." >&2
  restore_steam_download
  false
fi

echo "Removing the previous Steam download cache..."
remove_steam_download_backup

echo "Starting ${service}..."
docker compose up -d "$service"
service_stopped=false

trap - ERR
echo "Upgrade complete. Backup saved to ${backup_file}."
