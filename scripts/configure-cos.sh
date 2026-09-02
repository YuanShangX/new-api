#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

cos_env_file="${COS_ENV_FILE:-/etc/new-api/cos.env}"
cos_cmd="${COSCMD_BIN:-/opt/cos-sdk-venv/bin/coscmd}"
cos_cmd_config="${1:-${COSCMD_CONFIG:-/etc/new-api/coscmd.conf}}"
sdk_python="${COS_SDK_PYTHON:-/opt/cos-sdk-venv/bin/python}"
project_dir="${NEW_API_PROJECT_DIR:-/opt/new-api}"

[[ -r "${cos_env_file}" ]] || { echo "missing ${cos_env_file}" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "${cos_env_file}"
set +a
[[ "${COS_BACKUP_ENABLED:-0}" == "1" ]] || { echo "COS_BACKUP_ENABLED is not 1" >&2; exit 1; }
for name in COS_BUCKET COS_REGION COS_SECRET_ID COS_SECRET_KEY; do
  [[ -n "${!name:-}" ]] || { echo "missing ${name} in ${cos_env_file}" >&2; exit 1; }
done
[[ -x "${cos_cmd}" && -x "${sdk_python}" ]] || { echo "COS CLI/SDK installation is missing" >&2; exit 1; }

install -d -m 750 -o root -g ubuntu /etc/new-api
tmp_config="$(mktemp /etc/new-api/coscmd.conf.XXXXXX)"
cleanup() { rm -f -- "${tmp_config}"; }
trap cleanup EXIT

# coscmd writes only its local CLI configuration; stdout/stderr are suppressed
# so a future CLI change cannot put credential material into the journal.
"${cos_cmd}" -s -c "${tmp_config}" config \
  -a "${COS_SECRET_ID}" -s "${COS_SECRET_KEY}" \
  -b "${COS_BUCKET}" -r "${COS_REGION}" >/dev/null 2>&1
chown root:ubuntu "${tmp_config}"
chmod 640 "${tmp_config}"
mv -f -- "${tmp_config}" "${cos_cmd_config}"
trap - EXIT

"${sdk_python}" "${project_dir}/scripts/configure-cos.py"
echo "COS CLI configured at ${cos_cmd_config}"
