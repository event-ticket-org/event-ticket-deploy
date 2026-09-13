#!/usr/bin/env bash
# Creates a streaming standby as another cluster on this host.
#
#   sudo host/create-standby.sh standby1 5434
#
# Idempotent: a standby that already exists and is streaming is left alone.
#
# A cluster rather than a container, which is what Debian's packaging is for - pg_createcluster
# gives each one its own data directory, port, configuration tree and systemd unit, and they
# share only the postgres OS user. It is also closer to how this would be run in production than
# three containers would be.
set -euo pipefail

NAME=${1:?usage: create-standby.sh <name> <port>}
PORT=${2:?usage: create-standby.sh <name> <port>}
VERSION=${VERSION:-18}
PRIMARY_CLUSTER=${PRIMARY_CLUSTER:-eventticket}
PRIMARY_PORT=${PRIMARY_PORT:-5433}
ENV_FILE=${ENV_FILE:-/opt/event-ticket/event-ticket-deploy/.env}

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${REPLICATION_PASSWORD:?run host/prepare-replication.sh first}"

DATADIR="/var/lib/postgresql/$VERSION/$NAME"

echo "=== guard ==="
# Refuse to act unless the primary is the cluster we think it is. Everything below wipes a data
# directory, and the only thing standing between that and the live database is this check.
if ! pg_lsclusters -h | awk '{print $1, $2, $4}' | grep -qx "$VERSION $PRIMARY_CLUSTER online"; then
    echo "  $VERSION/$PRIMARY_CLUSTER is not online. Refusing." >&2
    exit 1
fi
case "$NAME" in
    "$PRIMARY_CLUSTER") echo "  '$NAME' is the primary. Refusing." >&2; exit 1 ;;
    ""|*/*|.*)          echo "  '$NAME' is not a plain cluster name. Refusing." >&2; exit 1 ;;
esac
echo "    primary $VERSION/$PRIMARY_CLUSTER is online; target is $VERSION/$NAME on $PORT"

if pg_lsclusters -h | awk '{print $1, $2, $4}' | grep -qx "$VERSION $NAME online"; then
    if sudo -u postgres psql -p "$PORT" -tAc 'select pg_is_in_recovery()' 2>/dev/null | grep -q t; then
        echo "    $VERSION/$NAME already exists and is in recovery - nothing to do"
        exit 0
    fi
    echo "  $VERSION/$NAME exists but is NOT a standby. Refusing to overwrite it." >&2
    exit 1
fi

echo
echo "=== 1. the replication slot, before the backup ==="
# Both halves matter. A slot created after the backup cannot protect the WAL the backup needs, so
# a busy primary can recycle a segment mid-clone and the standby starts and then dies looking for
# it. And immediately_reserve is what makes the slot reserve anything before something first
# connects to it - without it the slot reads as protection and provides none.
sudo -u postgres psql -p "$PRIMARY_PORT" -d postgres -v ON_ERROR_STOP=1 -c "
    select pg_create_physical_replication_slot('$NAME', true)
    where not exists (select 1 from pg_replication_slots where slot_name = '$NAME');" >/dev/null
echo "    slot '$NAME' reserved"

echo
echo "=== 2. an empty cluster to clone into ==="
# pg_createcluster is used for the configuration tree, the port registration and the systemd
# unit - not for the data, which comes from the primary. So its initdb output is discarded a few
# lines below.
if [ ! -d "/etc/postgresql/$VERSION/$NAME" ]; then
    pg_createcluster "$VERSION" "$NAME" --port "$PORT" >/dev/null
    echo "    created $VERSION/$NAME"
else
    echo "    configuration for $VERSION/$NAME already present"
fi
pg_ctlcluster "$VERSION" "$NAME" stop 2>/dev/null || true

echo
echo "=== 3. clone the primary ==="
# The path is rebuilt from VERSION and NAME, both of which were checked above, and the primary's
# own directory can never match because NAME was refused if it equalled PRIMARY_CLUSTER.
[ -n "$DATADIR" ] && [ "$DATADIR" != "/" ] || { echo "  refusing to touch '$DATADIR'" >&2; exit 1; }
rm -rf "${DATADIR:?}/"
install -d -o postgres -g postgres -m 0700 "$DATADIR"

# --dbname carries application_name so that -R records it in primary_conninfo.
# synchronous_standby_names matches on application_name and never on slot name, so a standby
# that omits it can never be made synchronous - and the omission is invisible until the day
# somebody tries.
PGPASSWORD="$REPLICATION_PASSWORD" sudo -u postgres --preserve-env=PGPASSWORD pg_basebackup \
    --dbname="host=127.0.0.1 port=$PRIMARY_PORT user=replicator application_name=$NAME" \
    --pgdata="$DATADIR" \
    --wal-method=stream \
    --slot="$NAME" \
    --write-recovery-conf \
    --checkpoint=fast \
    --no-password
chmod 0700 "$DATADIR"
echo "    cloned"

echo
echo "=== 4. let containers reach it ==="
# pg_createcluster writes a fresh configuration tree, so the standby does NOT inherit the
# primary's listen_addresses or pg_hba - those live in /etc on Debian and pg_basebackup only
# copies the data directory. A standby left on the defaults listens on loopback and refuses the
# docker bridge, which is invisible until the application tries to read from it.
CONF="/etc/postgresql/$VERSION/$NAME/postgresql.conf"
HBA="/etc/postgresql/$VERSION/$NAME/pg_hba.conf"
DOCKER_GW=${DOCKER_GW:-172.17.0.1}

if grep -qE "^listen_addresses" "$CONF"; then
    sed -i "s|^listen_addresses.*|listen_addresses = 'localhost,$DOCKER_GW'|" "$CONF"
else
    printf "\nlisten_addresses = 'localhost,%s'\n" "$DOCKER_GW" >> "$CONF"
fi
grep -qE '^host +all +all +172\.16\.0\.0/12' "$HBA" || \
    printf '\n# Containers on this host read from this standby through the docker bridge.\nhost    all             all             172.16.0.0/12           scram-sha-256\n' >> "$HBA"

# And the firewall, which is the one that fails silently: ufw governs the INPUT chain where
# container-to-host traffic lands, Docker's DOCKER-USER bypass does not apply, and it DROPS
# rather than refuses - so the symptom is a connection that hangs until it times out.
if command -v ufw >/dev/null 2>&1 && [ "$(ufw status | head -1)" != "Status: inactive" ]; then
    ufw status | grep -q "$PORT.*172.16.0.0/12" || \
        ufw allow from 172.16.0.0/12 to any port "$PORT" proto tcp \
            comment "event-ticket containers to $NAME" >/dev/null
    echo "    listen_addresses, pg_hba and ufw all allow the docker bridge"
else
    echo "    listen_addresses and pg_hba set; ufw inactive"
fi

echo
echo "=== 5. start it ==="
# pg_basebackup copies the primary's port into postgresql.auto.conf, which is read last and so
# beats the cluster's own configuration - two servers would then try to bind the same port and
# the second loses. The setting is removed rather than overridden, so the port stays wherever
# pg_createcluster registered it.
sudo -u postgres sed -i "/^port = /d" "$DATADIR/postgresql.auto.conf" 2>/dev/null || true
pg_ctlcluster "$VERSION" "$NAME" start
systemctl enable "postgresql@$VERSION-$NAME" >/dev/null 2>&1 || true

for _ in $(seq 1 30); do
    sudo -u postgres pg_isready -p "$PORT" >/dev/null 2>&1 && break
    sleep 1
done

echo
echo "=== what the primary now sees ==="
sudo -u postgres psql -p "$PRIMARY_PORT" -d "$DATABASE_NAME" -c "
    select application_name, state, sync_state,
           pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) as bytes_behind
    from pg_stat_replication order by application_name;"
echo "  $VERSION/$NAME in recovery: $(sudo -u postgres psql -p "$PORT" -tAc 'select pg_is_in_recovery()')"
