#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:---cached}"
case "${mode}" in
  --cached | --tracked) ;;
  *)
    echo "usage: $0 [--cached|--tracked]" >&2
    exit 2
    ;;
esac

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

failed=0
check_path() {
  local path="$1"
  local lower_path="${path,,}"
  local base="${lower_path##*/}"

  case "${lower_path}" in
    .env.example | */.env.example | deploy/cos.env.example)
      return
      ;;
  esac

  case "/${lower_path}" in
    /backups/* | /data/* | /pg_data/* | /postgres-data/* | /redis-data/* | /upload/*)
      echo "sensitive-file guard: forbidden data directory: ${path}" >&2
      failed=1
      return
      ;;
  esac

  case "${base}" in
    .env | .env.* | cos.env | coscmd.conf | *.agekey | *.pem | *.key | *.p12 | *.pfx | *.jks | *.keystore | id_rsa | id_dsa | id_ecdsa | id_ed25519 | new-api-env*.enc | *.dump | *.dump.gz | *.dump.sha256 | *.db | *.db-journal | *.sqlite | *.sqlite3 | .pgpass)
      echo "sensitive-file guard: forbidden secret or database file: ${path}" >&2
      failed=1
      return
      ;;
  esac

}

scan_content() {
  local pattern="$1"
  local message="$2"
  local -a grep_command=(git grep -I -l -z -E -e "${pattern}")
  if [[ "${mode}" == "--cached" ]]; then
    grep_command+=(--cached)
  fi
  grep_command+=(--)

  while IFS= read -r -d '' path; do
    # This provider adapter intentionally recognizes PEM service-account input;
    # it contains the marker as source code, not a working private key.
    if [[ "${message}" == private-key* && "${path}" == "relay/channel/vertex/service_account.go" ]]; then
      continue
    fi
    echo "sensitive-file guard: ${message}: ${path}" >&2
    failed=1
  done < <(LC_ALL=C "${grep_command[@]}" 2>/dev/null || true)
}

if [[ "${mode}" == "--cached" ]]; then
  while IFS= read -r -d '' path; do
    check_path "${path}"
  done < <(git diff --cached --name-only --diff-filter=ACMR -z)
else
  while IFS= read -r -d '' path; do
    check_path "${path}"
  done < <(git ls-files -z)
fi

private_key_pattern='-----BEGIN ([A-Z0-9 ]+ )?PRIV''ATE KEY-----|AGE-SECR''ET-KEY-|AK''ID[A-Za-z0-9]{24,}'
populated_secret_pattern='^(COS_SECRET_ID|COS_SECRET_KEY|POSTGRES_PASSWORD|REDIS_PASSWORD|SESSION_SECRET|DATABASE_URL|[A-Z0-9_]*API_KEY|[A-Z0-9_]*TOKEN)[[:space:]]*=[[:space:]]*[^<${[:space:]][^[:space:]]{7,}'
scan_content "${private_key_pattern}" "private-key or cloud-credential material detected"
scan_content "${populated_secret_pattern}" "populated production-secret assignment detected"

if [[ "${failed}" -ne 0 ]]; then
  echo "sensitive-file guard failed; nothing was uploaded by this check" >&2
  exit 1
fi

echo "sensitive-file guard passed (${mode})"
