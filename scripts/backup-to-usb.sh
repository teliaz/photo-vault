#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 /absolute/or/relative/path/to/backup.env" >&2
  exit 2
}

[[ $# -eq 1 && -f $1 ]] || usage
config_file=$(realpath -e -- "$1")
# This file is local operator configuration, not input from an untrusted user.
# shellcheck source=/dev/null
source "$config_file"

: "${IMMICH_COMPOSE_DIR:?Set IMMICH_COMPOSE_DIR in the config}"
: "${IMMICH_UPLOAD_DIR:?Set IMMICH_UPLOAD_DIR in the config}"
: "${USB_MOUNT:?Set USB_MOUNT in the config}"
: "${USB_UUID:?Set USB_UUID in the config}"
APP_SERVICE=${APP_SERVICE:-immich-server}
DB_SERVICE=${DB_SERVICE:-database}
DB_USERNAME=${DB_USERNAME:-postgres}
DB_DATABASE_NAME=${DB_DATABASE_NAME:-immich}

for path in "$IMMICH_COMPOSE_DIR" "$IMMICH_UPLOAD_DIR" "$USB_MOUNT"; do
  [[ $path = /* ]] || { echo "Paths must be absolute: $path" >&2; exit 2; }
  [[ -d $path ]] || { echo "Directory does not exist: $path" >&2; exit 2; }
done

command -v docker >/dev/null || { echo 'docker is required' >&2; exit 2; }
command -v borg >/dev/null || { echo 'borg 1.x is required' >&2; exit 2; }
command -v findmnt >/dev/null || { echo 'findmnt is required' >&2; exit 2; }
[[ $(borg --version) == 'borg 1.'* ]] || { echo 'This script requires Borg 1.x' >&2; exit 2; }

mount_path=$(realpath -e -- "$USB_MOUNT")
upload_path=$(realpath -e -- "$IMMICH_UPLOAD_DIR")
compose_path=$(realpath -e -- "$IMMICH_COMPOSE_DIR")
[[ $mount_path != / ]] || { echo 'USB_MOUNT cannot be /' >&2; exit 2; }
[[ $upload_path != "$mount_path" && $upload_path != "$mount_path"/* ]] || {
  echo 'The primary upload directory cannot be on the USB backup disk' >&2
  exit 2
}

mounted_uuid=$(findmnt --mountpoint "$mount_path" --noheadings --output UUID | xargs) || {
  echo "No filesystem is mounted at $mount_path" >&2
  exit 2
}
[[ -n $mounted_uuid && $mounted_uuid == "$USB_UUID" ]] || {
  echo "USB filesystem UUID mismatch at $mount_path" >&2
  exit 2
}
upload_uuid=$(findmnt --target "$upload_path" --noheadings --output UUID | xargs)
[[ -z $upload_uuid || $upload_uuid != "$mounted_uuid" ]] || {
  echo 'Primary uploads and USB backup are on the same filesystem' >&2
  exit 2
}

repo="$mount_path/immich-borg"
[[ -f $repo/config ]] || { echo "Initialize the Borg repository first: $repo" >&2; exit 2; }
[[ $(borg config "$repo" append_only) == 1 ]] || {
  echo 'The Borg repository must have append_only=1' >&2
  exit 2
}

[[ -f $compose_path/docker-compose.yml && -f $compose_path/.env ]] || {
  echo 'Expected docker-compose.yml and .env in IMMICH_COMPOSE_DIR' >&2
  exit 2
}

cd "$compose_path"
services=$(docker compose config --services)
grep -Fxq "$APP_SERVICE" <<< "$services" || {
  echo "Compose service not found: $APP_SERVICE" >&2
  exit 2
}
grep -Fxq "$DB_SERVICE" <<< "$services" || {
  echo "Compose service not found: $DB_SERVICE" >&2
  exit 2
}
[[ $(docker compose ps --status running --services "$APP_SERVICE") == "$APP_SERVICE" ]] || {
  echo "App service is not running: $APP_SERVICE" >&2
  exit 2
}
[[ $(docker compose ps --status running --services "$DB_SERVICE") == "$DB_SERVICE" ]] || {
  echo "Database service is not running: $DB_SERVICE" >&2
  exit 2
}

umask 077
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/photo-vault-backup.XXXXXXXX")
app_stopped=0
cleanup() {
  result=$?
  trap - EXIT
  if (( app_stopped )); then
    if ! docker compose start "$APP_SERVICE"; then
      echo "WARNING: could not restart $APP_SERVICE; restart it manually" >&2
      result=1
    fi
  fi
  rm -rf -- "$staging_dir"
  exit "$result"
}
trap cleanup EXIT

echo "Stopping $APP_SERVICE for a consistent backup..."
app_stopped=1
docker compose stop "$APP_SERVICE"

echo 'Dumping PostgreSQL...'
docker compose exec -T "$DB_SERVICE" pg_dump --clean --if-exists \
  --dbname="$DB_DATABASE_NAME" --username="$DB_USERNAME" \
  > "$staging_dir/immich-database.sql"
[[ -s $staging_dir/immich-database.sql ]] || {
  echo 'Database dump is empty' >&2
  exit 1
}
cp -- docker-compose.yml "$staging_dir/docker-compose.yml"
cp -- .env "$staging_dir/immich.env"

archive="immich-$(date -u +%Y%m%dT%H%M%SZ)"
echo "Creating $archive on $mount_path..."
(
  cd "$staging_dir"
  borg create --stats "$repo::$archive" "$upload_path" \
    immich-database.sql docker-compose.yml immich.env
)
echo "Backup complete: $repo::$archive"
