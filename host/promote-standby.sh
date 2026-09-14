#!/usr/bin/env bash
# Promotes a standby to primary.
#
#   sudo host/promote-standby.sh standby1
#
# This is the step nothing performs for you. PostgreSQL has no election and promotes nothing by
# itself: kill the primary and both standbys sit there reporting healthy and serving reads,
# indefinitely, until a human runs this. That is a property of the design, not an omission -
# Patroni is what changes it, and on a single machine it would add a coordination service that
# can demote a healthy primary when it hiccups.
#
# So the goal here is not automation. It is that the manual step takes thirty seconds and is not
# improvised at three in the morning.
set -euo pipefail

NAME=${1:?usage: promote-standby.sh <cluster>}
VERSION=${VERSION:-18}
OLD_PRIMARY=${OLD_PRIMARY:-eventticket}

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

port_of() { pg_lsclusters -h | awk -v v="$VERSION" -v c="$1" '$1==v && $2==c {print $3}'; }
PORT=$(port_of "$NAME")
[ -n "$PORT" ] || { echo "no cluster $VERSION/$NAME" >&2; exit 1; }

echo "=== before ==="
for c in $(pg_lsclusters -h | awk -v v="$VERSION" '$1==v {print $2}'); do
    p=$(port_of "$c")
    r=$(sudo -u postgres psql -p "$p" -tAc 'select pg_is_in_recovery()' 2>/dev/null | tr -d '\r')
    case "$r" in
        t) printf '  %-14s %s  standby\n' "$c" "$p" ;;
        f) printf '  %-14s %s  PRIMARY\n' "$c" "$p" ;;
        *) printf '  %-14s %s  unreachable\n' "$c" "$p" ;;
    esac
done

# Two primaries is the failure this guard exists for. Both would answer pg_is_in_recovery()
# false, HAProxy would keep both in the write pool, and it would balance writes across a real
# primary and a diverged one - which is worse than the outage being fixed.
if [ "$(sudo -u postgres psql -p "$(port_of "$OLD_PRIMARY")" -tAc 'select pg_is_in_recovery()' 2>/dev/null | tr -d '\r')" = "f" ]; then
    echo
    echo "  $OLD_PRIMARY is still accepting writes." >&2
    echo "  Stop it first, or promoting this standby leaves two primaries and HAProxy will" >&2
    echo "  balance writes across both:" >&2
    echo >&2
    echo "      sudo pg_ctlcluster $VERSION $OLD_PRIMARY stop -m fast" >&2
    exit 1
fi

if [ "$(sudo -u postgres psql -p "$PORT" -tAc 'select pg_is_in_recovery()' 2>/dev/null | tr -d '\r')" != "t" ]; then
    echo "  $NAME is not in recovery - it is not a standby." >&2
    exit 1
fi

echo
echo "=== promoting $NAME ==="
sudo -u postgres psql -p "$PORT" -qtAc 'select pg_promote(wait => true, wait_seconds => 60)' >/dev/null
for _ in $(seq 1 30); do
    [ "$(sudo -u postgres psql -p "$PORT" -tAc 'select pg_is_in_recovery()' 2>/dev/null | tr -d '\r')" = "f" ] && break
    sleep 1
done

echo "  in recovery now: $(sudo -u postgres psql -p "$PORT" -tAc 'select pg_is_in_recovery()' | tr -d '\r')   (f means promoted)"
echo "  timeline       : $(sudo -u postgres psql -p "$PORT" -tAc 'select timeline_id from pg_control_checkpoint()' | tr -d '\r')"

echo
echo "=== what happens next, and what does not ==="
cat <<TEXT
  HAProxy needs nothing. It asks every node pg_is_in_recovery() and will move the write door to
  $NAME within a few seconds - no configuration change, no restart. Check with:

      docker compose -f compose.yaml -f compose.override.yaml -f compose.replicated.yaml \\
          exec -T pg-haproxy sh -c 'echo ok'

  The application does NOT recover on its own. HikariCP holds connections to the node that just
  went away; on-marked-down shutdown-sessions closes them, and the pool has been seen not to
  recover from that within its 30s connectionTimeout. Expect to restart it:

      docker compose -f compose.yaml -f compose.override.yaml -f compose.replicated.yaml \\
          restart backend

  The old primary is NOT a standby now. It is a diverged node on an older timeline, and starting
  it as-is gives you two primaries. Either rewind it:

      sudo pg_ctlcluster $VERSION $OLD_PRIMARY start          # must be cleanly shut down first
      sudo -u postgres pg_rewind --target-pgdata=/var/lib/postgresql/$VERSION/$OLD_PRIMARY \\
          --source-server="host=127.0.0.1 port=$PORT user=replicator dbname=postgres"

  (pg_rewind works here because the clusters were created with --data-checksums.)

  Or rebuild it from scratch, which is simpler and takes seconds on a database this size:

      sudo pg_dropcluster $VERSION $OLD_PRIMARY --stop
      sudo host/create-standby.sh $OLD_PRIMARY <its old port>

  Either way, update PRIMARY_CLUSTER in your notes: the cluster named "$OLD_PRIMARY" is no longer
  the primary, and nothing renames it. That is the whole reason HAProxy asks rather than trusts.
TEXT
