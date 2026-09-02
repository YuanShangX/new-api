#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

project_dir="${NEW_API_PROJECT_DIR:-/opt/new-api}"
backup_dir="${NEW_API_BACKUP_DIR:-${project_dir}/backups/postgres}"
retention_days="${NEW_API_BACKUP_RETENTION_DAYS:-14}"
cos_env_file="${COS_ENV_FILE:-/etc/new-api/cos.env}"
cos_sdk_python="${COS_SDK_PYTHON:-/opt/cos-sdk-venv/bin/python}"
cos_uploader="${COS_UPLOADER:-${project_dir}/scripts/cos_backup.py}"
env_recipient_file="${COS_ENV_RECIPIENT_FILE:-/etc/new-api/env-recipient.txt}"

cd "${project_dir}"
mkdir -p "${backup_dir}"
chmod 700 "${project_dir}/backups" "${backup_dir}"

# The COS settings live outside the Git checkout.  Sourcing this file keeps
# credentials out of GitHub, deploy output, and command-line arguments.
if [[ -r "${cos_env_file}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${cos_env_file}"
  set +a
fi

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
cos_stem="new-api-${timestamp}.dump.gz"
gzip_path="${backup_dir}/${cos_stem}"
gzip_partial_path="${gzip_path}.partial"
checksum_path="${gzip_path}.sha256"
checksum_partial_path="${checksum_path}.partial"
config_partial_path="${project_dir}/.new-api-env-${timestamp}.enc.partial"

cleanup() {
  rm -f -- "${partial_path}" "${gzip_partial_path}" "${gzip_path}" \
    "${checksum_partial_path}" "${checksum_path}" "${config_partial_path}"
}
trap cleanup EXIT

docker compose exec -T postgres \
  pg_dump -U root -d new-api --format=custom --compress=6 --no-owner --no-acl \
  >"${partial_path}"

docker compose exec -T postgres pg_restore --list <"${partial_path}" >/dev/null
mv -- "${partial_path}" "${backup_path}"
sha256sum "${backup_path}" >"${backup_path}.sha256"

if [[ "${COS_BACKUP_ENABLED:-0}" == "1" ]]; then
  [[ -x "${cos_sdk_python}" ]] || {
    echo "COS SDK Python is not installed: ${cos_sdk_python}" >&2
    exit 1
  }
  [[ -f "${cos_uploader}" ]] || {
    echo "COS uploader is missing: ${cos_uploader}" >&2
    exit 1
  }
  [[ -r "${env_recipient_file}" ]] || {
    echo "age recipient file is missing: ${env_recipient_file}" >&2
    exit 1
  }

  recipient="$(tr -d '[:space:]' <"${env_recipient_file}")"
  [[ "${recipient}" =~ ^age1[[:alnum:]]+$ ]] || {
    echo "invalid age recipient in ${env_recipient_file}" >&2
    exit 1
  }

  gzip -c -- "${backup_path}" >"${gzip_partial_path}"
  mv -- "${gzip_partial_path}" "${gzip_path}"
  # Write the checksum after the atomic rename so it contains the final COS
  # filename, rather than the temporary local staging filename.
  (
    cd "$(dirname -- "${gzip_path}")"
    sha256sum "$(basename -- "${gzip_path}")"
  ) >"${checksum_partial_path}"
  mv -- "${checksum_partial_path}" "${checksum_path}"
  age -r "${recipient}" -o "${config_partial_path}" -- "${project_dir}/.env"

  "${cos_sdk_python}" "${cos_uploader}" \
    --dump "${gzip_path}" \
    --dump-checksum "${checksum_path}" \
    --config "${config_partial_path}" \
    --timestamp "${timestamp}"
  rm -f -- "${gzip_path}" "${checksum_path}" "${config_partial_path}"
else
  echo "COS upload is disabled; local PostgreSQL backup completed"
fi

find "${backup_dir}" -maxdepth 1 -type f \
  \( -name 'new-api_*.dump' -o -name 'new-api_*.dump.sha256' \) \
  -mtime "+$((retention_days - 1))" -delete

trap - EXIT
echo "PostgreSQL backup created: ${backup_path}"
