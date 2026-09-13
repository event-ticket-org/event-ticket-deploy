#!/usr/bin/env bash
# Moves the event-ticket database out of its container and into the host's 18/eventticket
# cluster, with the application stopped so nothing is written to the copy being left behind.
#
# The container and its volume are untouched. Rollback is one environment variable.
set -euo pipefail
cd /opt/event-ticket/event-ticket-deploy
set -a; . ./.env; set +a

HOST_PG=172.17.0.1
HOST_PORT=5433
OUT=/opt/event-ticket/backups
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

from_container() { docker exec event-ticket-postgres-1 "$@"; }
to_host() {
    docker run --rm -i -e PGPASSWORD="$DATABASE_PASSWORD" -v "$OUT:$OUT:ro" postgres:18 \
        psql -h "$HOST_PG" -p "$HOST_PORT" -U "$DATABASE_USERNAME" "$@"
}
host_q() { to_host -d "$DATABASE_NAME" -tAc "$1" 2>/dev/null | tr -d '\r'; }
cont_q() { from_container psql -U "$DATABASE_USERNAME" -d "$DATABASE_NAME" -tAc "$1" | tr -d '\r'; }

echo "=== 1. stop the application ==="
# A dump taken while the application is writing is consistent with itself and stale by the time
# it is restored - and the writes in that gap are orders. Stopping first costs a minute of API
# downtime and makes the window empty rather than small.
docker compose -f compose.yaml -f compose.override.yaml stop backend >/dev/null 2>&1
echo "    backend stopped"

echo
echo "=== 2. dump ==="
ROLES="$OUT/roles-$STAMP.sql"
DATA="$OUT/eventticket-$STAMP.sql"
# Roles separately, because pg_dump does not carry them and this schema depends on one:
# TenantAwareTransactionManager issues SET LOCAL ROLE eventticket_app at the start of every
# transaction, and the migration that created that role will not run again - the restored
# flyway_schema_history says it is already applied. Without the role, every transaction fails.
from_container pg_dumpall -U "$DATABASE_USERNAME" --roles-only > "$ROLES"
from_container pg_dump    -U "$DATABASE_USERNAME" -d "$DATABASE_NAME" > "$DATA"
echo "    roles: $(wc -l < "$ROLES") lines, data: $(du -h "$DATA" | cut -f1)"

echo
echo "=== 3. restore ==="
# Roles first, without ON_ERROR_STOP: the superuser role already exists on the target because
# the install script created it, so "role already exists" is the expected outcome for that one
# and must not stop the rest.
to_host -d postgres < "$ROLES" 2>&1 | grep -viE 'already exists|^$' | head -5 || true
to_host -d "$DATABASE_NAME" -v ON_ERROR_STOP=1 -q < "$DATA" > /dev/null
echo "    restored"

echo
echo "=== 4. does the copy match the original? ==="
printf '    %-28s %10s %10s  %s\n' table container host verdict
MISMATCH=0
for t in app_user organization membership venue event event_seat event_pricing_tier \
         ticket_order order_seat ticket payment_session payment_event refund scan \
         audit_entry email_delivery flyway_schema_history; do
    a=$(cont_q "select count(*) from $t")
    b=$(host_q  "select count(*) from $t")
    if [ "$a" = "$b" ]; then v=ok; else v="** MISMATCH **"; MISMATCH=1; fi
    printf '    %-28s %10s %10s  %s\n' "$t" "$a" "$b" "$v"
done

echo
echo "=== 5. the role the tenancy depends on ==="
host_q "select 'eventticket_app exists: ' || count(*) from pg_roles where rolname = 'eventticket_app'" | sed 's/^/    /'
host_q "select 'RLS-forced tables: ' || count(*) from pg_class where relrowsecurity and relforcerowsecurity" | sed 's/^/    /'
host_q "select 'unaccent extension: ' || count(*) from pg_extension where extname = 'unaccent'" | sed 's/^/    /'

echo
if [ "$MISMATCH" -eq 0 ]; then
    echo "=== every table matches. The backend is still stopped and still pointed at the container. ==="
else
    echo "=== MISMATCH above - do not repoint the backend. ==="
    exit 1
fi
