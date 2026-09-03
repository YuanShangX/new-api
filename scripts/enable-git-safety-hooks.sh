#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

git config --local core.hooksPath .githooks
chmod +x .githooks/pre-commit scripts/check-sensitive-files.sh
scripts/check-sensitive-files.sh --tracked
echo "repository-local Git safety hooks enabled"
