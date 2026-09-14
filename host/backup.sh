#!/usr/bin/env bash
#
# Back up everything needed to rebuild this deployment, and prove the backup can be read.
#
# Three things, because restoring any two of them leaves a system that does not work:
#
#   the database   orders, tickets, organizations - the irreplaceable part
#   the bucket     cover images; an Event whose poster 404s is not a restored Event
#   the secrets    and this is the one that surprises people. A Ticket Code is a random
#                  lookup plus a MAC under TICKET_CODE_KEY, and the code itself is never
#                  stored. Restore the database without that key and every outstanding ticket
#                  becomes unverifiable - a full house at the door and no way to admit anyone.
#
# So the archive contains credentials, and is written 0600. Anywhere it is copied to is as
# sensitive as the server.
#
# A backup nobody has restored is a hypothesis, so this one restores itself into a scratch
# database on every run and compares row counts. A dump that cannot be read fails here, at
# 03:00 on a quiet night, rather than on the morning it is needed.
set -euo pipefail

DEPLOY=/opt/event-ticket/event-ticket-deploy
DEST=${BACKUP_DEST:-/home/berserker/backups/event-ticket}
KEEP=${BACKUP_KEEP:-14}

cd "$DEPLOY"
set -a; . ./.env; set +a

# The database is a cluster on this host now, not a service in the stack, so everything below
# reaches it over TCP. Set once rather than edited at six call sites: the address has moved once
# already and may move again.
#
# This script ran for two nights against a `postgres` service that had ceased to exist. It failed
# loudly every time and nobody was looking, which is the actual lesson - the backup was correct
# right up until the deployment moved underneath it.
export PGHOST=${PGHOST:-127.0.0.1}
export PGPORT=${PGPORT:-5433}
export PGUSER=${DATABASE_USERNAME}
export PGPASSWORD=${DATABASE_PASSWORD}

stamp=$(date +%Y-%m-%d_%H%M%S)
out="$DEST/$stamp"
mkdir -p "$out"
chmod 700 "$DEST" "$out"

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$1"; }
fail() { log "FAILED: $1"; exit 1; }

# ── the database ──────────────────────────────────────────────────────────────
# Custom format: compressed, and pg_restore can read one table out of it without replaying
# the whole thing - which is what you actually want at 3am when one table is wrong.
log "dumping the database"
pg_dump -d "$DATABASE_NAME" -Fc > "$out/eventticket.dump" || fail "pg_dump"
[ -s "$out/eventticket.dump" ] || fail "the dump is empty"

# ── the bucket ────────────────────────────────────────────────────────────────
# A sync rather than tarring the Docker volume: what comes out is ordinary files that can be
# pushed back into any S3, including one that is not SeaweedFS.
#
# aws-cli rather than mc, and not as a preference. `minio/mc` cannot be pulled any more - MinIO
# withdrew its Docker Hub repository along with the server image - so the only copy of it was
# the one cached on this host, and a cleanup that judged it "no longer referenced" removed it.
# It was referenced: here. The replacement was chosen for not having that property.
log "mirroring the cover bucket"
mkdir -p "$out/covers"
# As this user, not root: the container would otherwise leave root-owned files that the
# retention sweep and the permissions tightening below cannot touch.
docker run --rm --network event-ticket_default \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e AWS_ACCESS_KEY_ID="$STORAGE_ACCESS_KEY" \
    -e AWS_SECRET_ACCESS_KEY="$STORAGE_SECRET_KEY" \
    -e AWS_DEFAULT_REGION="${STORAGE_REGION:-us-east-1}" \
    -e AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
    -e AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    -v "$out/covers:/backup" \
    amazon/aws-cli:latest \
    --endpoint-url "http://seaweedfs:9000" \
    s3 sync "s3://$STORAGE_BUCKET" /backup --only-show-errors || fail "s3 sync"

# A mirror that silently copied nothing is the failure worth catching here: the bucket is never
# legitimately empty once an Event has a cover, and an empty covers/ directory in a backup looks
# exactly like a successful run.
copied=$(find "$out/covers" -type f | wc -l)
[ "$copied" -gt 0 ] || fail "the cover mirror produced no files"
log "mirrored $copied object(s)"

# ── the secrets and the shape of the deployment ───────────────────────────────
log "copying configuration"
cp .env "$out/env"
cp compose.override.yaml "$out/" 2>/dev/null || true
# The one privileged read in this script, and it has a sudoers rule of its own naming exactly
# this command. `cat` with a redirect rather than `cp`: the shell creates the file as this user,
# so there is no second privileged step to grant.
sudo -n cat /etc/cloudflared/config.yml > "$out/cloudflared-config.yml" 2>/dev/null \
    || rm -f "$out/cloudflared-config.yml"
git -C ../event-ticket-backend rev-parse HEAD > "$out/backend.commit" 2>/dev/null || true
git -C ../event-ticket-frontend rev-parse HEAD > "$out/frontend.commit" 2>/dev/null || true

# ── prove it can be read ──────────────────────────────────────────────────────
# The whole point. Restoring into a scratch database exercises the dump end to end, and
# comparing counts catches a dump that restores but is missing rows.
log "restoring into a scratch database to check it"
scratch="restorecheck_$$"
psql -d postgres -c "drop database if exists $scratch" >/dev/null
psql -d postgres -c "create database $scratch" >/dev/null

restore_ok=yes
pg_restore -d "$scratch" --no-owner < "$out/eventticket.dump" >/dev/null 2>&1 || restore_ok=no

counts() {
    psql -d "$1" -tAc \
      "select (select count(*) from app_user) || '/' ||
              (select count(*) from organization) || '/' ||
              (select count(*) from event) || '/' ||
              (select count(*) from ticket_order) || '/' ||
              (select count(*) from ticket)" 2>/dev/null | tr -d '\r'
}
live=$(counts "$DATABASE_NAME")
copy=$(counts "$scratch")
psql -d postgres -c "drop database if exists $scratch" >/dev/null

[ "$restore_ok" = yes ] || fail "the dump would not restore"
[ -n "$copy" ] || fail "the restored copy could not be read"
if [ "$live" != "$copy" ]; then
    fail "restored counts differ - live $live, restored $copy"
fi
log "restore check passed  users/orgs/events/orders/tickets = $live"

# ── finish ────────────────────────────────────────────────────────────────────
printf '%s\n' "$live" > "$out/counts"
chmod -R go-rwx "$out"
du -sh "$out" | awk '{print "         size " $1}'

# ── retention ─────────────────────────────────────────────────────────────────
# Oldest first, keep the newest KEEP. Deliberately dumb: a clever rotation is a thing that can
# be wrong in a way nobody notices until there is nothing left to restore.
mapfile -t old < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | head -n -"$KEEP")
for directory in "${old[@]:-}"; do
    [ -n "$directory" ] || continue
    log "pruning $(basename "$directory")"
    rm -rf "$directory"
done

log "done  ->  $out"
ls -1 "$DEST" | tail -5 | sed 's/^/         /'
