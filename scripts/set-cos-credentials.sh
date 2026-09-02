#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

cos_env_file="${COS_ENV_FILE:-/etc/new-api/cos.env}"
cos_cmd_config="${COSCMD_CONFIG:-/etc/new-api/coscmd.conf}"
project_dir="${NEW_API_PROJECT_DIR:-/opt/new-api}"
sdk_python="${COS_SDK_PYTHON:-/opt/cos-sdk-venv/bin/python}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "run this helper with sudo" >&2
  exit 1
fi

read -r -p 'Tencent CAM SecretId (input hidden from logs): ' secret_id
printf '\n'
read -r -s -p 'Tencent CAM SecretKey (input hidden): ' secret_key
printf '\n'
[[ -n "${secret_id}" && -n "${secret_key}" ]] || {
  echo "SecretId and SecretKey are required" >&2
  exit 1
}

install -d -m 750 -o root -g ubuntu /etc/new-api
tmp_env="$(mktemp /etc/new-api/cos.env.XXXXXX)"
cleanup() { rm -f -- "${tmp_env}"; }
trap cleanup EXIT
{
  printf 'COS_BACKUP_ENABLED=1\n'
  printf 'COS_BUCKET=%q\n' 'new-api-backup-1329069407'
  printf 'COS_REGION=%q\n' 'ap-singapore'
  printf 'COS_SECRET_ID=%q\n' "${secret_id}"
  printf 'COS_SECRET_KEY=%q\n' "${secret_key}"
} >"${tmp_env}"
chown root:ubuntu "${tmp_env}"
chmod 640 "${tmp_env}"
mv -f -- "${tmp_env}" "${cos_env_file}"
trap - EXIT

# Configure the official coscmd CLI without echoing credentials.
set -a
# shellcheck disable=SC1090
source "${cos_env_file}"
set +a
"${project_dir}/scripts/configure-cos.sh" "${cos_cmd_config}"
echo "COS credentials installed and bucket policy settings applied; secret values were not displayed"
