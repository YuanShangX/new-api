# Production deployment and secret-safety knowledge base

This document is the durable safety reference for agents and operators working
on the New API production deployment. It applies even when a task only changes
a domain, Compose setting, backup script, or deployment helper.

## Asset boundaries

| Asset | Authoritative location | GitHub policy |
| --- | --- | --- |
| Source and deployment templates | GitHub repository | Tracked |
| Placeholder configuration | `.env.example`, `deploy/cos.env.example` | Tracked; placeholders only |
| Production application configuration | `/opt/new-api/.env` | Never tracked or printed |
| COS CAM credentials and CLI configuration | `/etc/new-api/cos.env`, `/etc/new-api/coscmd.conf` | Never tracked or printed |
| PostgreSQL production data | Docker Volume `new-api_pg_data` | Never copied into the repository |
| PostgreSQL local backups | `/opt/new-api/backups/postgres` | Never tracked |
| PostgreSQL offsite backups | Tencent COS `postgres/YYYY/MM/` | Never tracked |
| Encrypted production configuration | Tencent COS `config/new-api-env.enc` | Never tracked |
| age public recipient | Server `/etc/new-api/env-recipient.txt` | Public material; server only by convention |
| age private identity | Protected Windows backup outside the checkout | Never on server, COS, GitHub, or chat |

The repository must never contain working PostgreSQL or Redis passwords,
`SESSION_SECRET`, API keys, tokens, COS `SecretId`/`SecretKey`, private keys,
database dumps, database files, upload data, or Docker Volume data.

## Safe Git workflow

Before committing or pushing:

```bash
git status --short
git diff --cached --name-only
scripts/check-sensitive-files.sh --cached
```

Stage only explicit files. In deployment and operations work, do not use
`git add .` or `git add -A`. A clean guard result does not replace reviewing the
actual staged diff.

Enable the versioned local pre-commit hook once per clone:

```bash
scripts/enable-git-safety-hooks.sh
```

The hook and CI guard reject known secret/data filenames and common private-key
or populated production-secret patterns. The checks report filenames only and
must not print suspected values.

If a sensitive file is accidentally staged, remove only that path from the
index without deleting the local file:

```bash
git restore --staged -- path/to/file
```

If a working credential has already been pushed, assume compromise. Revoke or
rotate the credential immediately. Then coordinate repository-history cleanup;
a follow-up deletion commit does not remove the value from Git history.

## Safe production workflow

- Keep the server as a deployment target, not the primary coding environment.
- Keep New API bound to `127.0.0.1:3000`; expose only Caddy on ports 80/443.
- Keep PostgreSQL and Redis unexposed to the public network.
- Run a verified PostgreSQL backup before an application update or database
  migration.
- `docker compose down` preserves named volumes; never run
  `docker compose down -v` against production.
- Do not restore over an existing database unless the user has confirmed the
  exact database to overwrite. Prefer an empty database or separate validation
  database for restore tests.
- Do not output complete secrets in terminal commands, logs, chat, screenshots,
  documentation, or commit messages.

The normal application update remains:

```text
local change and test
  -> explicit Git commit and push
  -> server git pull --ff-only
  -> verified PostgreSQL backup
  -> docker compose up -d --build
  -> health checks
```

Production `.env` and COS credential files are server-local state. Changing a
domain may require both a tracked Caddy template change and a server-only trusted
URL update; the server-only value must never be copied back into Git.
