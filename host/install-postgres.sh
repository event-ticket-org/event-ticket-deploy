#!/usr/bin/env bash
# Gives event-ticket its own PostgreSQL 18 cluster on this host.
#
# Run with sudo. Idempotent - safe to run twice.
#
# ── What it deliberately does NOT do ─────────────────────────────────────────
#
# It does not touch cluster 16/main on port 5432. That belongs to okrs-backend, and Debian's
# packaging exists precisely so two versions and two clusters can share a host without meeting:
# separate data directory, separate port, separate systemd unit, separate postgres processes.
# The only thing they share is the `postgres` OS user.
#
# It does not move any data. The restore happens afterwards, over TCP, with the application's
# own credentials - nothing here needs to see them.
set -euo pipefail

VERSION=18
CLUSTER=eventticket
PORT=5433
DOCKER_GW=${DOCKER_GW:-172.17.0.1}

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

echo "=== 1. the PostgreSQL project's apt repository ==="
# Ubuntu 24.04 packages 16 and nothing newer. The data being moved was written by 18, and
# restoring down a major version is the direction that breaks - so the repository is added
# rather than the data converted.
if [ -f /etc/apt/sources.list.d/pgdg.list ]; then
    echo "    already configured"
else
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo "$VERSION_CODENAME")-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
    echo "    added"
fi
apt-get update -qq

echo
echo "=== 2. postgresql-$VERSION ==="
if dpkg -s "postgresql-$VERSION" >/dev/null 2>&1; then
    echo "    already installed"
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "postgresql-$VERSION" >/dev/null
    echo "    installed"
fi

# Installing the package creates a default cluster on the next free port. It is not the one this
# script is making, it holds nothing, and leaving it would start a second server for no reason.
if pg_lsclusters -h | awk '{print $1, $2}' | grep -qx "$VERSION main"; then
    echo "    dropping the empty default cluster $VERSION/main that the package created"
    pg_dropcluster "$VERSION" main --stop
fi

echo
echo "=== 3. the cluster ==="
if pg_lsclusters -h | awk '{print $1, $2}' | grep -qx "$VERSION $CLUSTER"; then
    echo "    $VERSION/$CLUSTER already exists"
else
    # --data-checksums explicitly. It is the default in 18, and it is what lets pg_rewind work
    # without wal_log_hints - which is the difference between rebuilding a demoted primary from
    # a full basebackup and rewinding it. Too important to inherit silently.
    pg_createcluster "$VERSION" "$CLUSTER" --port "$PORT" -- --data-checksums >/dev/null
    echo "    created $VERSION/$CLUSTER on port $PORT"
fi

echo
echo "=== 4. let the containers reach it ==="
CONF="/etc/postgresql/$VERSION/$CLUSTER/postgresql.conf"
HBA="/etc/postgresql/$VERSION/$CLUSTER/pg_hba.conf"

# The docker bridge address and loopback, and nothing else. Not '*': this host has a LAN
# interface and a wireless one, and a database that answers on them is a database exposed to
# every device on the network.
if grep -qE "^listen_addresses" "$CONF"; then
    sed -i "s|^listen_addresses.*|listen_addresses = 'localhost,$DOCKER_GW'|" "$CONF"
else
    printf "\nlisten_addresses = 'localhost,%s'\n" "$DOCKER_GW" >> "$CONF"
fi

# Docker's default bridge networks live in 172.16.0.0/12. scram, never trust - a trust rule here
# would accept any container on this host, including ones no part of this project started.
if grep -qE '^host +all +all +172\.16\.0\.0/12' "$HBA"; then
    echo "    pg_hba rule already present"
else
    printf '\n# Containers on this host reach the database through the docker bridge.\nhost    all             all             172.16.0.0/12           scram-sha-256\n' >> "$HBA"
    echo "    pg_hba rule appended"
fi

pg_ctlcluster "$VERSION" "$CLUSTER" start 2>/dev/null || pg_ctlcluster "$VERSION" "$CLUSTER" reload
systemctl enable "postgresql@$VERSION-$CLUSTER" >/dev/null 2>&1 || true

echo
echo "=== 5. the application's role and database ==="
# Created here because only the postgres OS user can authenticate to a brand new cluster. The
# password comes from the deployment's own .env, so this script never invents a credential and
# nothing has to be typed twice.
ENV_FILE=/opt/event-ticket/event-ticket-deploy/.env
set -a; . "$ENV_FILE"; set +a

sudo -u postgres psql -p "$PORT" -v ON_ERROR_STOP=1 -v u="$DATABASE_USERNAME" -v pw="$DATABASE_PASSWORD" <<'SQL' >/dev/null
set my.u  = :'u';
set my.pw = :'pw';
do $$
begin
    if exists (select 1 from pg_roles where rolname = current_setting('my.u')) then
        execute format('alter role %I with login superuser password %L', current_setting('my.u'), current_setting('my.pw'));
    else
        execute format('create role %I with login superuser password %L', current_setting('my.u'), current_setting('my.pw'));
    end if;
end
$$;
SQL

# SUPERUSER, matching what the container image gives POSTGRES_USER, and it is load-bearing here
# rather than laziness: this schema's tenant isolation depends on the connection user being able
# to SET LOCAL ROLE to the unprivileged eventticket_app role, and the Flyway migrations create
# roles and a trusted extension. A plain owner cannot do either.
sudo -u postgres psql -p "$PORT" -tAc \
    "select 1 from pg_database where datname = '$DATABASE_NAME'" | grep -q 1 || \
    sudo -u postgres createdb -p "$PORT" -O "$DATABASE_USERNAME" "$DATABASE_NAME"
echo "    role and database ready"

echo
echo "=== 6. the host firewall ==="
# Found the hard way. ufw governs the INPUT chain, which is where container-to-host traffic
# lands - Docker's own DOCKER-USER bypass does not apply to it. Without this rule the packets
# are DROPPED rather than refused, so the container waits for a timeout and reports the server
# as unreachable, which reads exactly like the database being down.
if ! command -v ufw >/dev/null 2>&1 || [ "$(ufw status | head -1)" = "Status: inactive" ]; then
    echo "    ufw not active, nothing to add"
elif ufw status | grep -q "5433.*172.16.0.0/12"; then
    echo "    rule already present"
else
    ufw allow from 172.16.0.0/12 to any port "$PORT" proto tcp \
        comment "event-ticket containers to host postgres" >/dev/null
    echo "    allowed 172.16.0.0/12 -> $PORT (docker bridges only, not the LAN)"
fi

echo
echo "=== what now exists ==="
pg_lsclusters
echo
echo "  16/main is untouched and still belongs to okrs-backend."
