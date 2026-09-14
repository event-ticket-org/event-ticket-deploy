# event-ticket-deploy

Runs the product behind one origin: the backend and the frontend as containers, SeaweedFS beside
them, and **the database on the host**.

```bash
git clone https://github.com/event-ticket-org/event-ticket-backend.git
git clone https://github.com/event-ticket-org/event-ticket-frontend.git
git clone https://github.com/event-ticket-org/event-ticket-deploy.git
cd event-ticket-deploy
./build.sh                        # builds both images, and writes .env with generated secrets
sudo host/install-postgres.sh     # the database cluster, under systemd
docker compose up -d
open http://localhost:8081
```

## Where each thing runs, and why

| | Where | |
|---|---|---|
| backend, frontend | **containers** | stateless. The image tag is the version; if an image is lost you rebuild it from source. |
| PostgreSQL | **host**, systemd, its own cluster | state you cannot rebuild |
| SeaweedFS | container, for now | state you cannot rebuild either — it should follow |

The line is not "containers bad". It is **which things hold state that cannot be reconstructed**.
A backend container is disposable by definition. A database volume is not.

That distinction was not theoretical here. MinIO archived its community edition and withdrew its
Docker Hub repository, and every `minio/minio` tag became unpullable at once — the pinned release
included. The running container survived only because the image happened to still be on the disk.
A stateful service whose runtime can be withdrawn by a third party is a stateful service one
`docker image prune` away from being gone.

The host database also gets what the packaging already does well: `pg_upgradecluster` for major
versions, apt security updates, systemd ordering that starts it before Docker, and
`pg_createcluster` for running several clusters side by side — which is how the standbys are
meant to be run, and closer to production than three containers would be.

`host/` carries the provisioning: `install-postgres.sh` creates the cluster,
`migrate-container-to-host.sh` moves an existing containerised database into it, and
`prepare-replication.sh` makes it replicable. All three are idempotent.

**Three things must agree before a container can reach the host database**: `listen_addresses`,
`pg_hba.conf`, and the host firewall. The firewall is the one that fails silently — `ufw` governs
the INPUT chain where container-to-host traffic lands, Docker's `DOCKER-USER` bypass does not
apply, and it **drops** rather than refuses. The symptom is a connection timeout that reads
exactly like the database being down. `install-postgres.sh` sets all three.

`build.sh` expects the other two repositories beside this one. Override with `BACKEND_REPO` and
`FRONTEND_REPO`, or skip it entirely and set `BACKEND_IMAGE` / `FRONTEND_IMAGE` in `.env` to
images from a registry — `compose.yaml` only ever refers to tags.

## Read replicas, optional

```bash
sudo host/prepare-replication.sh          # the primary: role, pg_hba, WAL bound. No restart.
sudo host/create-standby.sh standby1 5434
sudo host/create-standby.sh standby2 5435
docker compose -f compose.yaml -f compose.replicated.yaml up -d
```

The overlay adds an HAProxy container and points **both** of the application's database addresses
at it — `:5000` for writes, `:5001` for replica reads.

**Neither is a hostname.** HAProxy asks every node `pg_is_in_recovery()` and routes on the
answer, because after a promotion the names are wrong and nothing renames them: the cluster
called `standby1` becomes the one accepting writes while the one called `eventticket` is the one
in recovery. `option pgsql-check` cannot express this — it opens a connection and sends a startup
packet, which proves a server is alive and says nothing about whether it accepts writes. So the
image carries `psql` and an `external-check` script.

`on-marked-down shutdown-sessions` is what makes the check mean anything. Without it HAProxy
stops sending *new* connections to a failed node and leaves established ones alone — and HikariCP
holds connections open for minutes, so the pool would go on writing to a node the check had
already condemned.

**It follows a promotion; it does not perform one.** Nothing here elects anything, and Postgres
has no election. Patroni is what closes that gap, and its absence is deliberate.

Standbys are **further clusters on this host**, not containers — `pg_createcluster` plus
`pg_basebackup`, each with its own data directory, port, configuration tree and systemd unit.
That is what Debian's packaging is for, and it keeps the standbys in the same place as the
primary rather than splitting one cluster across two runtimes.

`create-standby.sh` is idempotent and refuses to touch a cluster that is not a standby. It
creates the replication slot **before** the basebackup and with `immediately_reserve`: a slot
made afterwards cannot protect the WAL that backup needs, and one without the flag reserves
nothing until something first connects to it — protection in name only.

**A standby inherits none of the primary's access configuration.** `pg_createcluster` writes a
fresh tree, `listen_addresses` and `pg_hba.conf` live in `/etc` on Debian, and `pg_basebackup`
only copies the data directory. So each standby needs the same three things the primary needed —
`listen_addresses`, a `pg_hba` rule, and a `ufw` rule — and the firewall is again the one that
fails silently, because it drops rather than refuses and the symptom is a hang. The script does
all three.

`prepare-replication.sh` never needs `wal_log_hints`, because `install-postgres.sh` creates the
cluster with `--data-checksums` and checksums give `pg_rewind` the same guarantee. It bounds
`max_slot_wal_keep_size`, which defaults to unlimited — the dangerous direction, since a standby
that stops consuming pins WAL until the disk fills and a full disk stops the **primary**.
Bounding it inverts that: a standby down too long loses its slot and is rebuilt. That is the
failure worth having.

Replication is **asynchronous**. `synchronous_standby_names` with no standby left freezes every
write on the primary indefinitely while `pg_isready` still answers healthy. When it is wanted the
shape is `ANY 1 (standby1, standby2)` — quorum commit runs at the speed of the fastest standby,
where naming a single one ties every commit to that node forever. The standbys record
`application_name`, which is what that setting matches on, never the slot name.

**On one machine this does not buy availability.** The clusters share a disk, a kernel and a
power supply, and Postgres promotes nothing by itself — measured, not assumed: kill the primary
and the standbys sit there reporting healthy and serving reads until a human runs `pg_promote()`.
What it buys is read capacity, a backup target off the node serving traffic, and somewhere to
rehearse a failover before performing one for real.

## What this is not

It is not the development stack. `event-ticket-backend/compose.yaml` starts the two things a
developer needs *behind* a locally-run application, and that is still how you work on the code:

```bash
docker compose up -d && ./mvnw spring-boot:run    # in event-ticket-backend
npm run dev                                       # in event-ticket-frontend
```

The two publish some of the same ports, so run one or the other.

## The shape of a deployment

Four things are true here that are not true on a laptop, and each of them was a bug before it
was a line of configuration.

**One origin.** nginx serves the built client and proxies `/api` to the backend, so the browser
sees a single host. That is not a convenience: `src/api/client.ts` asks for `/api/v1` relative
to wherever it was served and never learns a backend address, which is what keeps CORS out of
the system entirely. The backend is not published at all.

**The object store has three addresses.** They are the same string on a laptop and stop being
it the moment the backend runs in a container:

| | who uses it | why it is separate |
|---|---|---|
| `STORAGE_ENDPOINT` | the backend's SDK | `seaweedfs:9000` — a name only the container network resolves |
| `STORAGE_UPLOAD_BASE_URL` | the browser, posting a cover | must be reachable from outside Docker |
| `STORAGE_PUBLIC_BASE_URL` | the browser, fetching a cover | may be a CDN, which can serve a picture and cannot accept one |

A presigned POST policy signs the policy document rather than the host, so the same signature
is valid at any address that reaches the same bucket.

**Every emailed link is built from `APP_BASE_URL`.** Address verification, a ticket, a refund
notice. Change the port after people hold tickets and their links break.

**No credential has a default.** `application.yml` names them with no fallback, so a container
started without `JWT_SECRET`, `TICKET_CODE_KEY`, `DATABASE_PASSWORD`, `STORAGE_SECRET_KEY` or
`FAKE_PAYMENT_SECRET` refuses to boot. That is deliberate and it is the arrangement where
forgetting is safe: the development values live in the backend's `dev` profile, which this
image does not have. `TICKET_CODE_KEY` is the heavy one — nothing that grants entry is stored,
so a leaked database is not a set of working tickets, and that key is what makes it true.

`./build.sh` generates all five the first time. They are in `.env`, which is gitignored;
`env.example` is the readable copy and holds no values.

## Payment

`VITE_PAYMENT_PROVIDER` is compiled into the client, because `import.meta.env` is replaced at
build time — so changing it means `./build.sh` again, not an environment variable. `FAKE` is
the default and needs nothing. `STRIPE` needs `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`
in `.env`; empty means there is no Stripe provider at all, rather than one that fails on first
use.

Neither half of the money can be completed from a browser, by design: an order becomes paid
only on a provider's webhook and a refund settles only on one. On a laptop nothing sends those,
so the backend's `scripts/confirm-payment.sh` and `scripts/confirm-refund.sh` act as the
provider. They work against this stack unchanged:

```bash
BASE=http://localhost:8081/api/v1 \
PG_CONTAINER=event-ticket-postgres-1 \
FAKE_PAYMENT_SECRET=$(grep '^FAKE_PAYMENT_SECRET=' .env | cut -d= -f2) \
  ../event-ticket-backend/scripts/confirm-payment.sh <order-id>
```

**These two scripts do not work against a host database yet.** They reach Postgres with
`docker exec "$PG_CONTAINER" psql`, which needs a container that no longer exists here. Teaching
them to take a connection string instead is a change in event-ticket-backend, not this
repository. Until then, run them against the development stack, where the database is still a
container.

## The first administrator

Set `PLATFORM_ADMIN_EMAILS` in `.env` before the first sign-up. An account named there is
promoted when it registers, and at start-up if it registered already. It is the only way to
become a platform admin and the only privilege no request can grant — approving organizations
decides who may sell tickets at all, so conferring it needs access to the deployment rather
than to the product. With it empty, no organization can ever be approved and nothing can be
published.

## What is missing

This runs the product; it does not operate it. There is no TLS, no backups, no log shipping,
no secret store, and `nfr.md`'s single instance is taken literally — admission rate limiting is
per process, so a second backend would double the limit rather than share it.
