#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${project_dir}"

exec 9>"${project_dir}/.deploy.lock"
if ! flock -n 9; then
  echo "another deployment is already running" >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  echo "missing ${project_dir}/.env" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "tracked files have local changes; refusing to deploy" >&2
  exit 1
fi

git pull --ff-only origin main
docker compose config --quiet

postgres_id="$(docker compose ps -q postgres)"
if [[ -z "${postgres_id}" ]] || [[ "$(docker inspect -f '{{.State.Running}}' "${postgres_id}")" != "true" ]]; then
  echo "PostgreSQL must be running before an update deployment" >&2
  exit 1
fi

"${project_dir}/scripts/backup-postgres.sh"

export NEW_API_IMAGE_TAG="$(git rev-parse --short=12 HEAD)"
docker compose build --pull new-api
docker compose up -d --remove-orphans

deadline=$((SECONDS + 240))
while (( SECONDS < deadline )); do
  new_api_id="$(docker compose ps -q new-api)"
  if [[ -n "${new_api_id}" ]] && [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${new_api_id}")" == "healthy" ]]; then
    break
  fi
  sleep 5
done

new_api_id="$(docker compose ps -q new-api)"
if [[ -z "${new_api_id}" ]] || [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${new_api_id}")" != "healthy" ]]; then
  docker compose ps >&2
  docker compose logs --tail=100 new-api >&2
  echo "New API did not become healthy within 240 seconds" >&2
  exit 1
fi

docker compose exec -T postgres psql -U root -d new-api -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null
docker compose exec -T redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping' | grep -q PONG
curl --fail --silent --show-error http://127.0.0.1:3000/api/status >/dev/null

docker compose ps
echo "Deployment healthy at commit $(git rev-parse HEAD)"
