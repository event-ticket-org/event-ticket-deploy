#!/usr/bin/env bash
# Makes the host's event-ticket cluster replicable, without restarting it.
#
# Run with sudo, after host/install-postgres.sh. Idempotent - it runs against a primary that is
# usually already prepared and usually serving traffic.
#
# Everything here is a catalogue change or a SIGHUP parameter. The one setting that would have
# forced a restart is wal_log_hints, and it is deliberately absent: PostgreSQL 18 turns data
# checksums on at initdb and checksums give pg_rewind the same guarantee. install-postgres.sh
# passes --data-checksums explicitly rather than inheriting that default, precisely so this
# remains true if the default ever moves.
set -euo pipefail

VERSION=${VERSION:-18}
CLUSTER=${CLUSTER:-eventticket}
PORT=${PORT:-5433}
ENV_FILE=${ENV_FILE:-/opt/event-ticket/event-ticket-deploy/.env}

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

HBA="/etc/postgresql/$VERSION/$CLUSTER/pg_hba.conf"
as_pg() { sudo -u postgres psql -p "$PORT" -v ON_ERROR_STOP=1 "$@"; }

echo "=== 1. a password for the replicator role ==="
if grep -q '^REPLICATION_PASSWORD=' "$ENV_FILE"; then
    echo "    already in .env, reusing it"
else
    {
        printf '\n# The replicator role. Streaming replication only - it owns nothing and can read\n'
        printf '# no table, so it is not a second way into the data.\n'
        printf 'REPLICATION_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    } >> "$ENV_FILE"
    echo "    generated and appended to .env"
fi
set -a; . "$ENV_FILE"; set +a

echo
echo "=== 2. the replicator role ==="
# REPLICATION and LOGIN and nothing else. A standby receives blocks, not rows, so a grant on any
# table here would widen what one leaked password reaches without enabling anything.
as_pg -d "$DATABASE_NAME" -v pw="$REPLICATION_PASSWORD" <<'SQL' >/dev/null
-- Through a session setting: psql substitutes :'pw' in an ordinary statement but not inside
-- dollar quoting, so the obvious spelling sets the password to the literal text and succeeds.
set my.pw = :'pw';
do $$
begin
    if exists (select 1 from pg_roles where rolname = 'replicator') then
        execute format('alter role replicator with replication login password %L', current_setting('my.pw'));
    else
        execute format('create role replicator with replication login password %L', current_setting('my.pw'));
    end if;
end
$$;
SQL
echo "    present"

echo
echo "=== 3. let standbys authenticate ==="
# Standbys are other clusters on this host, so they arrive over loopback. The packaged pg_hba
# already trusts local replication; this adds the scram rule for anything reaching it by TCP.
if grep -qE '^host +replication +replicator ' "$HBA"; then
    echo "    rule already present"
else
    printf '\n# Standby clusters stream from here. scram, never trust.\nhost    replication     replicator      127.0.0.1/32            scram-sha-256\nhost    replication     replicator      172.16.0.0/12           scram-sha-256\n' >> "$HBA"
    echo "    appended"
fi

echo
echo "=== 4. bound the WAL a dead standby can pin ==="
# Unbounded retention means a standby that stops consuming pins WAL until the disk fills, and a
# full disk stops the primary - trading a broken replica for a broken site. The bound inverts
# that: a standby down longer than this loses its slot and must be rebuilt from a basebackup.
as_pg -d "$DATABASE_NAME" -c "alter system set max_slot_wal_keep_size = '8GB';" >/dev/null

# Asserted rather than assumed. A primary that cannot stream should say so here, not through a
# standby that clones and then cannot start.
as_pg -d "$DATABASE_NAME" -c "
do \$\$
declare bad text;
begin
    select string_agg(name || ' = ' || setting, ', ') into bad from pg_settings
     where (name = 'wal_level' and setting not in ('replica','logical'))
        or (name = 'max_wal_senders' and setting::int < 4)
        or (name = 'max_replication_slots' and setting::int < 4);
    if bad is not null then raise exception 'cannot support standbys: %', bad; end if;
end
\$\$;" >/dev/null

pg_ctlcluster "$VERSION" "$CLUSTER" reload
echo "    bounded, configuration reloaded"

echo
echo "=== ready ==="
as_pg -d "$DATABASE_NAME" -c "select name, setting from pg_settings where name in ('wal_level','max_wal_senders','max_replication_slots','max_slot_wal_keep_size','data_checksums') order by name;"
echo "  Synchronous replication is deliberately NOT enabled. synchronous_standby_names with no"
echo "  standby left freezes every write while pg_isready still answers healthy. When it is"
echo "  wanted, the shape is: ANY 1 (standby1, standby2) - quorum commit runs at the speed of"
echo "  the fastest standby, where naming one ties every commit to that node forever."
