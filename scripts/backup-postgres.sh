#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

project_dir="${NEW_API_PROJECT_DIR:-/opt/new-api}"
backup_dir="${NEW_API_BACKUP_DIR:-${project_dir}/backups/postgres}"
retention_days="${NEW_API_BACKUP_RETENTION_DAYS:-14}"

cd "${project_dir}"
mkdir -p "${backup_dir}"
chmod 700 "${project_dir}/backups" "${backup_dir}"

exec 9>"${backup_dir}/.backup.lock"
if ! flock -n 9; then
  echo "another PostgreSQL backup is already running" >&2
  exit 1
fi

postgres_id="$(docker compose ps -q postgres)"
if [[ -z "${postgres_id}" ]] || [[ "$(docker inspect -f '{{.State.Running}}' "${postgres_id}")" != "true" ]]; then
  echo "PostgreSQL container is not running" >&2
  exit 1
fi

timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
partial_path="${backup_dir}/new-api_${timestamp}.dump.partial"
backup_path="${partial_path%.partial}"

cleanup() {
  rm -f -- "${partial_path}"
}
trap cleanup EXIT

docker compose exec -T postgres \
  pg_dump -U root -d new-api --format=custom --compress=6 --no-owner --no-acl \
  >"${partial_path}"

docker compose exec -T postgres pg_restore --list <"${partial_path}" >/dev/null
mv -- "${partial_path}" "${backup_path}"
sha256sum "${backup_path}" >"${backup_path}.sha256"

find "${backup_dir}" -maxdepth 1 -type f \
  \( -name 'new-api_*.dump' -o -name 'new-api_*.dump.sha256' \) \
  -mtime "+$((retention_days - 1))" -delete

trap - EXIT
echo "PostgreSQL backup created: ${backup_path}"
