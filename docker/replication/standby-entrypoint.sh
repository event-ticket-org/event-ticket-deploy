#!/usr/bin/env bash
# Clones the primary on first boot, then behaves like any other postgres container.
#
# Unlike the learning cluster in event-ticket-backend, the primary here already exists and is
# serving a live site. Nothing here writes to it beyond creating this standby's own replication
# slot, and nothing about it requires the primary to restart.
#
# This runs as root, because a named volume arrives owned by root and only root can hand it to
# postgres. Everything that touches the cluster then drops to postgres through gosu - initdb and
# pg_basebackup refuse to run as root outright, and a clone performed as root would leave a data
# directory the server cannot open.
set -euo pipefail

: "${PRIMARY_HOST:?}" "${REPLICATION_SLOT:?}" "${PGPASSWORD:?}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPLICATION_USER="${REPLICATION_USER:-replicator}"
PGDATA="${PGDATA:-/var/lib/postgresql/data}"

mkdir -p "$PGDATA"
chown -R postgres:postgres "$PGDATA"

if [ -s "$PGDATA/PG_VERSION" ]; then
    echo "standby: $PGDATA already holds a cluster, starting it"
else
    echo "standby: waiting for $PRIMARY_HOST:$PRIMARY_PORT"
    until gosu postgres pg_isready -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPLICATION_USER" >/dev/null 2>&1; do
        sleep 1
    done

    # The slot first, and reserving immediately.
    #
    # Both halves are load-bearing. A slot created after the backup cannot protect the WAL that
    # backup needs, so a busy primary can recycle a segment mid-clone and the standby starts and
    # then dies looking for it. And a slot created without immediately_reserve reserves nothing
    # until something first connects to it - which is exactly the window being closed, so it
    # reads as protection and is not.
    echo "standby: creating replication slot $REPLICATION_SLOT"
    gosu postgres psql -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$REPLICATION_USER" -d postgres \
        -v ON_ERROR_STOP=1 -c "
        select pg_create_physical_replication_slot('$REPLICATION_SLOT', true)
        where not exists (select 1 from pg_replication_slots where slot_name = '$REPLICATION_SLOT');" >/dev/null

    echo "standby: cloning the primary"
    # --dbname carries application_name so that -R writes it into primary_conninfo. Not
    # cosmetic: synchronous_standby_names matches on application_name and never on slot name, so
    # a standby that omits it can never be made synchronous - and the omission is invisible
    # until the day somebody tries.
    gosu postgres pg_basebackup \
        --dbname="host=$PRIMARY_HOST port=$PRIMARY_PORT user=$REPLICATION_USER application_name=$REPLICATION_SLOT" \
        --pgdata="$PGDATA" \
        --wal-method=stream \
        --slot="$REPLICATION_SLOT" \
        --write-recovery-conf \
        --checkpoint=fast \
        --progress --no-password

    chmod 0700 "$PGDATA"
    chown -R postgres:postgres "$PGDATA"
    echo "standby: clone complete"
fi

exec gosu postgres "$@"
