# NinetyNine Freight — Shipment Tracking

A deliberately small, stage-legible shipment-tracking application split across four
Linux VMs, built for the Microsoft Ignite 2026 breakout on migrating a mixed-distro
Linux estate from on-premises Hyper-V to Azure.

The application exists so that a migration is **visible** rather than described:
each tier reports which host, which distro and which platform served the request,
so the dashboard flips from "Hyper-V" to "Azure" tier-by-tier as cutover proceeds.

| Tier   | Host           | Distro | Runs                                          |
|--------|----------------|--------|-----------------------------------------------|
| db     | `rhel-db`      | RHEL   | SQL Server 2025 on Linux — schema + work queue |
| api    | `sles-api`     | SLES   | FastAPI / uvicorn — all business logic         |
| web    | `ubuntu-web`   | Ubuntu | nginx + FastAPI — dashboard, public tracking   |
| worker | `rocky-worker` | Rocky  | Queue consumer, scan generator, telemetry      |

## Addressing: IPs first, DNS later

The estate runs on an isolated Hyper-V subnet with no DNS, so **on-prem you reach
everything by IP**. The web tier never hard-codes a hostname — it advertises the
address the browser actually used, so the board is always truthful.

| Stage | Dashboard | Tracking page | API |
|---|---|---|---|
| Hyper-V (now) | `http://192.168.90.13/` | `http://192.168.90.13/track` | `http://192.168.90.12:8080` |
| Azure (after cutover) | `https://dash.99b.org` | `https://track.99b.org` | `https://api.99b.org` |

Switching to the `99b.org` names is a **one-line change** in
`/etc/shipment/shipment.env` on the web tier:

```ini
SHIPMENT_TRACK_URL=https://track.99b.org
```

Leave it blank until DNS actually resolves. That single line is the last step of
the migration and the only part of it the audience sees.

## Why it is shaped this way

Every architectural choice serves the demo, not enterprise purity.

1. **The database is also the queue.** No Redis or RabbitMQ VM. `scan_queue` is a
   SQL Server table claimed with `UPDATE ... WITH (READPAST) OUTPUT`. When `rhel-db`
   fails to boot after migration, the board freezes and the worker starves — one
   broken VM produces four visibly degraded tiers.
2. **Every tier reports where it lives.** `/healthz` returns hostname, the
   `/etc/os-release` pretty name, kernel version, and whether the host is on-premises
   or in Azure (detected via IMDS at `169.254.169.254`). This drives the health strip,
   which is the single most important visual in the session.
3. **Nothing is containerised.** Real VMs, real systemd units, real `/etc/fstab`
   entries, real distro package managers — because the session is about migrating VMs.
4. **The data model is five tables you can read from the back of the room.**

## Layout

```
common/   shared identity + health helper, vendored into each tier
db/       schema, seed data, SQL Server install for RHEL
api/      FastAPI service for SLES
web/      dashboard + public tracking site for Ubuntu
worker/   queue consumer + scan generator for Rocky
tools/    smoke test, load generator, estate reset helpers
docs/     architecture and demo notes
```

Each tier has an idempotent `install-*.sh` that assumes a genuinely on-premises
flavoured host: static IP, no walinuxagent, no Azure cloud-init.

## Estate addressing

Defaults assume the Hyper-V internal switch `192.168.90.0/24`:

| Host         | On-prem IP    |
|--------------|---------------|
| rhel-db      | 192.168.90.11 |
| sles-api     | 192.168.90.12 |
| ubuntu-web   | 192.168.90.13 |
| rocky-worker | 192.168.90.14 |

Everything is overridable via `/etc/shipment/shipment.env`, which is the only file
that changes when the estate lands in Azure with new addresses. Start from
`shipment.env.example`; never commit a populated `shipment.env`.

## Quick start

```bash
sudo ./db/install-mssql-rhel.sh        # on rhel-db
sudo ./api/install-sles.sh             # on sles-api
sudo depot login -u <org> -t <token>   # on rocky-worker
sudo depot enable rlc-plus-10.2         # enables the matching online repos
sudo ./web/install-ubuntu.sh            # on ubuntu-web
sudo ./worker/install-rocky.sh         # on rocky-worker
./tools/smoke-test.sh                  # from anywhere on the lab subnet
```

See [`docs/architecture.md`](docs/architecture.md) for the data flow and
[`docs/demo-notes.md`](docs/demo-notes.md) for the stage beats.

## Licence

MIT. See [LICENSE](LICENSE).
