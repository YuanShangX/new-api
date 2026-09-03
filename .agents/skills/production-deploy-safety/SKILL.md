---
name: production-deploy-safety
description: Safely deploy, update, back up, restore, or change domains for this New API production environment while preventing secrets, database data, backups, and Docker Volume contents from entering Git or logs.
---

# Production deploy safety

Use this skill for production-server, Docker Compose, Caddy/domain, PostgreSQL,
Redis, COS backup, restore, credential, Git commit, or GitHub push work in this
repository.

Before acting, read `../../../docs/PRODUCTION_SECURITY.md`. Preserve these
non-negotiable boundaries:

- Git may contain source, deployment templates, scripts, placeholder examples,
  and recovery instructions only.
- Never stage, commit, push, log, or display production `.env` content;
  PostgreSQL/Redis/session passwords; API keys or tokens; COS credentials;
  private keys; database dumps/files; uploaded data; or Docker Volume contents.
- The server holds `/opt/new-api/.env`, `/etc/new-api/cos.env`, and
  `/etc/new-api/coscmd.conf`. The age private identity stays only in the
  operator's protected Windows backup location. COS receives ciphertext only.
- PostgreSQL data remains in `new-api_pg_data`. Never run
  `docker compose down -v`, delete/recreate the Volume, or restore over an
  existing database without explicit authorization for that exact target.

For Git mutations:

1. Inspect `git status --short` and preserve unrelated user files.
2. Stage explicit paths only; do not use `git add .` or `git add -A` for
   deployment/operations work.
3. Inspect `git diff --cached --name-only` and the staged diff.
4. Run `scripts/check-sensitive-files.sh --cached` before commit and push.
5. If the guard identifies a file, unstage that exact file without printing it.
   If a working secret was already pushed, stop, report exposure, and require
   credential rotation before any history cleanup.

For production mutations, back up before risky changes, validate configs before
reload, use health checks after changes, and verify that `new-api_pg_data` still
exists. Keep secret values out of command output and the final report.
