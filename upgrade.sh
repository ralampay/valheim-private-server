#!/usr/bin/env bash

set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

service="valheim"
backup_dir="backups"
upgrade_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_file="${backup_dir}/pre-upgrade-${upgrade_timestamp}.tar.gz"
steam_app_manifest="data/server/dl/server/steamapps/appmanifest_896660.acf"
steam_app_manifest_backup="${steam_app_manifest}.pre-upgrade-${upgrade_timestamp}"
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
if ! download_valheim; then
  if [[ ! -f "$steam_app_manifest" ]]; then
    echo "SteamCMD failed and no app manifest is available for recovery." >&2
    false
  fi

  echo "SteamCMD failed; backing up its app manifest and retrying once..." >&2
  mv -- "$steam_app_manifest" "$steam_app_manifest_backup"

  if ! download_valheim; then
    echo "SteamCMD retry failed; restoring the previous app manifest." >&2
    mv -f -- "$steam_app_manifest_backup" "$steam_app_manifest"
    false
  fi

  echo "SteamCMD recovered. Previous app manifest saved to ${steam_app_manifest_backup}."
fi

echo "Starting ${service}..."
docker compose up -d "$service"
service_stopped=false

trap - ERR
echo "Upgrade complete. Backup saved to ${backup_file}."
