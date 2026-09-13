#!/usr/bin/env bash
# Makes an existing primary replicable, without restarting it.
#
# Idempotent on purpose: this runs on every `up` of the replicated overlay, against a primary
# that is usually already prepared and is usually serving traffic. Everything below is either a
# catalogue change or a SIGHUP parameter.
#
# What is deliberately absent is wal_log_hints, the one setting here that would force a restart.
# PostgreSQL 18 turns data checksums on at initdb, and checksums give pg_rewind the same
# guarantee - so the primary keeps running. wal_level, max_wal_senders and max_replication_slots
# are all adequate at their defaults; they are asserted at the end rather than assumed, because
# a primary initialised by some other hand may not be.
set -euo pipefail

: "${PRIMARY_HOST:?}" "${POSTGRES_USER:?}" "${POSTGRES_DB:?}" "${REPLICATION_PASSWORD:?}"
HBA="${PGDATA:-/var/lib/postgresql/data}/pg_hba.conf"

psql_() { psql -h "$PRIMARY_HOST" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 "$@"; }

until pg_isready -h "$PRIMARY_HOST" -U "$POSTGRES_USER" >/dev/null 2>&1; do sleep 1; done

# REPLICATION and LOGIN and nothing else. A role that streams WAL needs no rights on any table -
# a standby receives blocks, not rows - so a grant here would only widen what one leaked
# password reaches.
psql_ -v pw="$REPLICATION_PASSWORD" <<'SQL' >/dev/null
-- Through a session setting rather than straight into the block: psql substitutes :'pw' in an
-- ordinary statement and not inside dollar quoting, so the obvious spelling would set the
-- password to the literal text :'pw' and report success.
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
echo "primary-init: replicator role present"

# The image ships replication rules for loopback only, so a standby in another container is
# refused with a message about no pg_hba entry - which reads like a network fault and is not.
if grep -qE '^host +replication +replicator ' "$HBA"; then
    echo "primary-init: pg_hba rule already present"
else
    printf '\n# Standbys stream from here. scram, never trust.\nhost replication replicator all scram-sha-256\n' >> "$HBA"
    echo "primary-init: pg_hba rule appended"
fi

# Unbounded retention means a standby that stops consuming pins WAL until the disk is full, and
# a full disk stops the primary - trading a broken replica for a broken site. The bound inverts
# that: a standby down longer than 8GB of WAL has its slot invalidated and must be rebuilt from
# a fresh basebackup, which is the failure worth having.
psql_ -c "alter system set max_slot_wal_keep_size = '8GB';" >/dev/null
psql_ -c "select pg_reload_conf();" >/dev/null
echo "primary-init: max_slot_wal_keep_size bounded, configuration reloaded"

# Asserted, not assumed. A primary that cannot stream says so here rather than through a standby
# that clones and then cannot start.
psql_ -tAc "
do \$\$
declare bad text;
begin
    select string_agg(name || ' = ' || setting, ', ') into bad from pg_settings
     where (name = 'wal_level' and setting not in ('replica','logical'))
        or (name = 'max_wal_senders' and setting::int < 4)
        or (name = 'max_replication_slots' and setting::int < 4);
    if bad is not null then
        raise exception 'primary cannot support standbys: %', bad;
    end if;
end
\$\$;" >/dev/null
echo "primary-init: primary is able to stream"
