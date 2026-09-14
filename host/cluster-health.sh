#!/usr/bin/env bash
# Asks the cluster the questions pg_isready cannot answer.
#
#   sudo host/cluster-health.sh          # report and exit 0/1
#   systemctl status cluster-health      # the timer's last verdict
#
# This exists because every standard check was green through eight distinct failures produced on
# purpose in event-ticket-backend's docs/replication/01-what-went-wrong.md:
#
#   synchronous replication with no standby left   healthy, writes frozen indefinitely
#   replication slot invalidated, standby dead     healthy, serving 223,841 rows of 296,564
#   standby query killed by recovery conflict      healthy, the error only reaches the client
#   primary dead, nothing promoted                 healthy on both standbys, cluster read-only
#
# pg_isready answers "is a process listening". It cannot say whether that process is replicating,
# how far behind it is, whether it can still accept a write, or whether it is a primary at all.
# Every one of those is a separate query, and a deployment that does not run them is not
# monitoring its cluster.
set -uo pipefail

VERSION=${VERSION:-18}
PRIMARY=${PRIMARY:-eventticket}
PRIMARY_PORT=${PRIMARY_PORT:-5433}
STANDBYS=${STANDBYS:-"standby1:5434 standby2:5435"}
READ_STANDBY=${READ_STANDBY:-standby1}
LAG_WARN_BYTES=${LAG_WARN_BYTES:-33554432}        # 32MB
DISK_WARN_PCT=${DISK_WARN_PCT:-85}
BACKUP_DIR=${BACKUP_DIR:-/home/berserker/backups/event-ticket}
BACKUP_MAX_AGE_HOURS=${BACKUP_MAX_AGE_HOURS:-48}

problems=0
note()  { printf '  %-52s %s\n' "$1" "$2"; }
bad()   { printf '  %-52s ** %s **\n' "$1" "$2"; problems=$((problems + 1)); }
q()     { sudo -u postgres psql -p "$1" -tAc "$2" 2>/dev/null | tr -d '\r'; }

echo "=== nodes ==="
# Answering at all is the necessary part. It is only the first question.
for spec in "$PRIMARY:$PRIMARY_PORT" $STANDBYS; do
    name=${spec%%:*}; port=${spec##*:}
    if [ "$(q "$port" 'select 1')" = "1" ]; then
        recovery=$(q "$port" 'select pg_is_in_recovery()')
        if [ "$name" = "$PRIMARY" ]; then
            [ "$recovery" = "f" ] && note "$name ($port)" "primary, accepting writes" \
                                  || bad  "$name ($port)" "IN RECOVERY - this node is not the primary"
        else
            [ "$recovery" = "t" ] && note "$name ($port)" "standby, in recovery" \
                                  || bad  "$name ($port)" "NOT IN RECOVERY - promoted, or diverged"
        fi
    else
        bad "$name ($port)" "unreachable"
    fi
done

echo
echo "=== replication, as the primary sees it ==="
# The question a standby cannot answer about itself: a standby that has silently stopped
# receiving still serves reads, still reports healthy, and simply falls further behind.
for spec in $STANDBYS; do
    name=${spec%%:*}
    row=$(q "$PRIMARY_PORT" "select state || ' ' || coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn), -1)
                             from pg_stat_replication where application_name = '$name'")
    if [ -z "$row" ]; then
        bad "$name" "NOT CONNECTED to the primary"
        continue
    fi
    state=${row%% *}; lag=${row##* }
    if [ "$state" != "streaming" ]; then
        bad "$name" "state is '$state', not streaming"
    elif [ "$lag" -gt "$LAG_WARN_BYTES" ] 2>/dev/null; then
        bad "$name" "streaming but ${lag} bytes behind"
    else
        note "$name" "streaming, ${lag} bytes behind"
    fi
done

echo
echo "=== replication slots ==="
# A slot whose wal_status is 'lost' means the primary has already discarded WAL that standby
# needed. The standby is then permanently broken and will never catch up - and it goes on
# answering queries with stale data while reporting healthy.
# `active` is rendered by a CASE rather than concatenated directly. Postgres resolves
# `text || boolean` through anynonarray and renders it 'true'/'false', where psql DISPLAYS a
# boolean column as 't'/'f' - so a test against 't' marks every healthy slot inactive. That is
# precisely the failure this script exists to catch, arriving in the script itself.
slots=$(q "$PRIMARY_PORT" "select slot_name || ' ' || (case when active then 'yes' else 'no' end)
                                  || ' ' || coalesce(wal_status, '?') from pg_replication_slots")
if [ -z "$slots" ]; then
    bad "slots" "none exist - standbys have no WAL retention guarantee"
else
    echo "$slots" | while read -r nm act st; do
        if [ "$st" = "lost" ]; then
            printf '  %-52s ** WAL LOST - this standby must be rebuilt **\n' "$nm"
        elif [ "$act" != "yes" ]; then
            printf '  %-52s ** inactive - nothing is consuming it **\n' "$nm"
        else
            printf '  %-52s %s\n' "$nm" "active, $st"
        fi
    done
    # The loop above runs in a subshell, so it cannot raise `problems`. Counted again here.
    n=$(echo "$slots" | awk '$3 == "lost" || $2 != "yes"' | wc -l)
    [ "$n" -gt 0 ] && problems=$((problems + n))
fi

echo
echo "=== the trap that freezes writes silently ==="
# synchronous_standby_names naming a standby that is gone does not fail. It blocks every commit,
# indefinitely, while pg_isready goes on answering healthy.
sync_names=$(q "$PRIMARY_PORT" 'show synchronous_standby_names')
if [ -z "$sync_names" ]; then
    note "synchronous_standby_names" "empty - asynchronous, commits cannot block"
else
    connected=$(q "$PRIMARY_PORT" "select count(*) from pg_stat_replication where sync_state <> 'async'")
    [ "${connected:-0}" -gt 0 ] && note "synchronous_standby_names" "'$sync_names', $connected synchronous standby(s) connected" \
                               || bad  "synchronous_standby_names" "'$sync_names' but NO synchronous standby connected - writes will block"
fi

echo
echo "=== capacity and backups ==="
used=$(df --output=pcent /var/lib/postgresql 2>/dev/null | tail -1 | tr -dc '0-9')
[ "${used:-0}" -ge "$DISK_WARN_PCT" ] && bad "disk used" "${used}% - WAL retention can fill this" \
                                      || note "disk used" "${used}%"

newest=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null | sort | tail -1)
if [ -z "$newest" ]; then
    bad "backup" "none found in $BACKUP_DIR"
else
    age=$(( ( $(date +%s) - $(stat -c %Y "$newest") ) / 3600 ))
    if [ "$age" -gt "$BACKUP_MAX_AGE_HOURS" ]; then
        bad "backup" "newest is ${age}h old ($(basename "$newest"))"
    # `counts` is written only after backup.sh has restored the dump into a scratch database and
    # matched its row counts against live. A dump that exists is not a backup; a dump that has
    # been read back is.
    elif [ ! -s "$newest/counts" ]; then
        bad "backup" "$(basename "$newest") has no restore-check result - the dump was never read back"
    else
        note "backup" "${age}h old, restore-checked ($(cat "$newest/counts"))"
    fi
fi

# The unit, not just its output. A backup that failed leaves a failed unit and nothing else
# would mention it here.
if systemctl is-failed --quiet event-ticket-backup.service 2>/dev/null; then
    bad "event-ticket-backup.service" "FAILED on its last run - journalctl -u event-ticket-backup"
else
    note "event-ticket-backup.service" "$(systemctl is-active event-ticket-backup.service 2>/dev/null || echo unknown)"
fi

echo
if [ "$problems" -eq 0 ]; then
    echo "=== healthy ==="
else
    echo "=== $problems problem(s) - see the marked lines above ==="
fi
exit $(( problems > 0 ))
