#!/usr/bin/env bash
# Encrypts the newest backup and pushes it somewhere this machine is not.
#
#   host/offsite-sync.sh            # run as the user that owns the backups
#
# Until this runs, every copy of the data is on one logical volume: the database at
# /var/lib/postgresql and its backups at ~/backups are the same physical device. A disk failure
# takes the data and every backup of it together, and the restore-check that passes nightly is
# then proving something about a file that no longer exists.
#
# ── Why it encrypts, and why that is not optional ────────────────────────────
#
# The archive contains .env: JWT_SECRET, TICKET_CODE_KEY, the database password, the storage
# keys, the Stripe keys. backup.sh already says anywhere it is copied to is as sensitive as the
# server - and "anywhere" now means a bucket at a company you have an account with. The archive
# is encrypted here, before it leaves, so the destination holds ciphertext and nothing else.
#
# TICKET_CODE_KEY is the reason this matters more than it looks. A ticket code is a random
# lookup plus a MAC under that key, and the code itself is never stored - so whoever holds this
# archive in the clear can mint tickets.
#
# ── The passphrase must not live only here ───────────────────────────────────
#
# An encrypted backup whose key exists only on the machine you just lost is not a backup. Put
# BACKUP_PASSPHRASE in a password manager the day you set it, and never anywhere else.
set -euo pipefail

DEPLOY=${DEPLOY:-/opt/event-ticket/event-ticket-deploy}
SRC=${BACKUP_DEST:-/home/berserker/backups/event-ticket}
KEEP=${OFFSITE_KEEP:-30}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cd "$DEPLOY"
set -a; . ./.env; set +a

log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$1"; }
fail() { printf '%s  FAILED: %s\n' "$(date +%H:%M:%S)" "$1" >&2; exit 1; }

: "${OFFSITE_ENDPOINT:?set OFFSITE_ENDPOINT in .env}"
: "${OFFSITE_BUCKET:?set OFFSITE_BUCKET in .env}"
: "${OFFSITE_ACCESS_KEY:?set OFFSITE_ACCESS_KEY in .env}"
: "${OFFSITE_SECRET_KEY:?set OFFSITE_SECRET_KEY in .env}"
: "${BACKUP_PASSPHRASE:?set BACKUP_PASSPHRASE in .env}"

# A short passphrase on an archive that mints tickets is not worth the disk it is written to.
[ "${#BACKUP_PASSPHRASE}" -ge 24 ] || fail "BACKUP_PASSPHRASE is shorter than 24 characters"

newest=$(find "$SRC" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -1)
[ -n "$newest" ] || fail "no backup found in $SRC"
name=$(basename "$newest")

# Only ship a backup that proved it could be read. backup.sh writes `counts` after restoring its
# own dump into a scratch database and matching row counts against live - so its absence means
# the restore check did not pass, and shipping that copy off-site would be shipping a hope.
[ -s "$newest/counts" ] || fail "$name has no restore-check result - not shipping an unverified backup"

log "packing $name ($(du -sh "$newest" | cut -f1))"
tar -C "$SRC" -cf - "$name" | gzip \
    | gpg --batch --yes --symmetric --cipher-algo AES256 --compress-algo none \
          --passphrase-fd 3 --output "$WORK/$name.tar.gz.gpg" 3<<<"$BACKUP_PASSPHRASE" \
    || fail "encryption"

# Read it back before trusting it. The same rule the local backup already follows: an archive
# that has not been decrypted is a hypothesis, and a passphrase typo produces a perfectly valid
# file that nothing can open.
log "decrypting it again to check"
gpg --batch --quiet --decrypt --passphrase-fd 3 "$WORK/$name.tar.gz.gpg" 3<<<"$BACKUP_PASSPHRASE" 2>/dev/null \
    | gzip -dc | tar -tf - > "$WORK/listing" || fail "the encrypted archive does not decrypt"
entries=$(wc -l < "$WORK/listing")
grep -q "$name/eventticket.dump" "$WORK/listing" || fail "the archive does not contain the database dump"
log "decrypts cleanly, $entries entries, dump present"

size=$(stat -c %s "$WORK/$name.tar.gz.gpg")
log "uploading $((size / 1024))KB to $OFFSITE_BUCKET"

# The two checksum variables are set because newer aws-cli sends checksum headers that several
# S3 implementations - R2 among them - reject outright.
s3() {
    docker run --rm \
        --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -e AWS_ACCESS_KEY_ID="$OFFSITE_ACCESS_KEY" \
        -e AWS_SECRET_ACCESS_KEY="$OFFSITE_SECRET_KEY" \
        -e AWS_DEFAULT_REGION="${OFFSITE_REGION:-auto}" \
        -e AWS_REQUEST_CHECKSUM_CALCULATION=when_required \
        -e AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
        -v "$WORK:/work" \
        amazon/aws-cli:latest --endpoint-url "$OFFSITE_ENDPOINT" "$@"
}

s3 s3 cp "/work/$name.tar.gz.gpg" "s3://$OFFSITE_BUCKET/$name.tar.gz.gpg" --only-show-errors \
    || fail "upload"

# An upload that reported success and stored nothing is the failure this catches. The remote
# size is the cheapest thing that distinguishes them.
remote=$(s3 s3api head-object --bucket "$OFFSITE_BUCKET" --key "$name.tar.gz.gpg" \
         --query ContentLength --output text 2>/dev/null | tr -d '\r')
[ "$remote" = "$size" ] || fail "uploaded $size bytes, remote reports ${remote:-nothing}"
log "verified $remote bytes at the destination"

# Retention, oldest first. Deliberately dumb: a clever rotation is a thing that can be wrong in
# a way nobody notices until there is nothing left to restore.
mapfile -t remote_keys < <(s3 s3api list-objects-v2 --bucket "$OFFSITE_BUCKET" \
    --query 'sort_by(Contents,&Key)[].Key' --output text 2>/dev/null | tr '\t' '\n' | grep -E '^20.*\.gpg$' || true)
count=${#remote_keys[@]}
if [ "$count" -gt "$KEEP" ]; then
    for key in "${remote_keys[@]:0:$((count - KEEP))}"; do
        s3 s3 rm "s3://$OFFSITE_BUCKET/$key" --only-show-errors && log "pruned $key"
    done
fi

log "done  $count copy(ies) off-site, keeping $KEEP"
