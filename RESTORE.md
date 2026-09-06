# New API disaster recovery

This runbook restores a new Ubuntu host from the GitHub source, the encrypted
production environment file in Tencent COS, and a PostgreSQL dump in COS. It
does not delete the existing `new-api_pg_data` volume. On a host that might
contain data, stop and inspect it before restoring; restore only into an empty,
newly-created PostgreSQL volume or a separately named database.

## 1. Prepare a replacement host

Install Docker Engine, Compose v2, `age`, and the official Tencent COS CLI/SDK,
then clone the repository and check out the desired commit:

```bash
sudo install -d -m 755 /opt/new-api
sudo chown "$USER":"$USER" /opt/new-api
git clone https://github.com/YuanShangX/new-api /opt/new-api
cd /opt/new-api
git checkout <commit>
```

Use the same deployment installer and COS CLI virtual environment as the
production host. Create the dedicated CAM child-user credentials on the host
through a secure prompt; never put them in GitHub or this document.

## 2. Recover the encrypted `.env`

Configure the official `coscmd` CLI with the dedicated backup-bucket CAM user,
then download the latest configuration object. The object is encrypted to the
age recipient whose private key is kept only on the operator's Windows machine:

```bash
coscmd -c /etc/new-api/coscmd.conf \
  download config/new-api-env.enc /tmp/new-api-env.enc
```

On Windows, decrypt `/tmp/new-api-env.enc` (copy the ciphertext to Windows by
SFTP; do not copy the private key to the server):

```powershell
age -d -i 'D:\Desktop\Computer\Backups\new-api\new-api-env.agekey' `
  -o '.\.env' '.\new-api-env.enc'
```

Transfer the resulting `.env` to `/opt/new-api/.env` over SSH/SFTP, then set
permissions on the server:

```bash
sudo chown ubuntu:ubuntu /opt/new-api/.env
sudo chmod 600 /opt/new-api/.env
```

The age private key must never be stored on the replacement server or in COS.

## 3. Restore PostgreSQL

Start only PostgreSQL and Redis first, and wait for both health checks:

```bash
cd /opt/new-api
docker compose up -d postgres redis
docker compose ps
```

List objects under `postgres/YYYY/MM/` and select a dump. Download both the
compressed dump and its checksum, then verify the compressed object before
restoring:

```bash
coscmd -c /etc/new-api/coscmd.conf \
  download postgres/YYYY/MM/new-api-YYYYMMDDTHHMMSSZ.dump.gz /tmp/new-api.dump.gz
coscmd -c /etc/new-api/coscmd.conf \
  download postgres/YYYY/MM/new-api-YYYYMMDDTHHMMSSZ.dump.gz.sha256 /tmp/new-api.dump.gz.sha256
(cd /tmp && sha256sum -c new-api.dump.gz.sha256)
```

Only restore into a verified empty database/volume. Without dropping anything,
restore the custom-format dump and start New API:

```bash
gzip -dc /tmp/new-api.dump.gz \
  | docker compose exec -T postgres pg_restore \
      --exit-on-error --no-owner --no-acl -U root -d new-api
docker compose up -d new-api
docker compose ps
curl --fail https://api.vectorecho.site/api/status
```

If the replacement host is not empty or the dump/database choice is unclear,
stop before running `pg_restore` and make a separate database/volume. Never use
`docker compose down -v` on a host containing data.

## 4. Re-enable scheduled backups

Install the repository's `deploy/new-api-backup.service` and
`deploy/new-api-backup.timer`, place the COS settings in
`/etc/new-api/cos.env` (mode `0640`, owned by `root:ubuntu`), and verify:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now new-api-backup.timer
sudo systemctl list-timers new-api-backup.timer
sudo systemctl start new-api-backup.service
sudo journalctl -u new-api-backup.service -n 100 --no-pager
```

The service keeps local PostgreSQL dumps under
`/opt/new-api/backups/postgres` for 14 days and uploads compressed dumps below
`postgres/YYYY/MM/` plus the encrypted configuration at
`config/new-api-env.enc`. COS lifecycle rules retain current objects for 90
days and clean noncurrent versions after 30 days.
