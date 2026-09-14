#!/usr/bin/env bash
# Turns on off-site backups. One step, because the parts only make sense together.
#
#   sudo host/enable-offsite.sh \
#       --endpoint https://<account>.r2.cloudflarestorage.com \
#       --bucket   event-ticket-backups \
#       --key      <access key id> \
#       --secret   <secret access key>
#
# Generates the encryption passphrase if there is not one, installs the systemd wiring, and runs
# a real sync so the thing is proven before it is trusted.
#
# The passphrase is generated here rather than earlier on purpose. A key that exists before
# anybody is ready to write it down is a key nobody writes down - and an encrypted backup whose
# passphrase lives only on the machine you lost is not a backup.
set -euo pipefail

DEPLOY=${DEPLOY:-/opt/event-ticket/event-ticket-deploy}
ENV_FILE="$DEPLOY/.env"
OWNER=${OWNER:-berserker}

ENDPOINT="" BUCKET="" KEY="" SECRET="" REGION=auto
while [ $# -gt 0 ]; do
    case "$1" in
        --endpoint) ENDPOINT=$2; shift 2 ;;
        --bucket)   BUCKET=$2;   shift 2 ;;
        --key)      KEY=$2;      shift 2 ;;
        --secret)   SECRET=$2;   shift 2 ;;
        --region)   REGION=$2;   shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done
[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }
for v in ENDPOINT BUCKET KEY SECRET; do
    [ -n "${!v}" ] || { echo "--${v,,} is required" >&2; exit 1; }
done

echo "=== 1. credentials for the destination ==="
# Appended rather than rewritten: .env holds every secret this deployment has, and a script that
# regenerates it is a script that can lose one.
add() {
    grep -q "^$1=" "$ENV_FILE" && { echo "    $1 already set, leaving it"; return; }
    printf '%s=%s\n' "$1" "$2" >> "$ENV_FILE"
    echo "    $1 added"
}
grep -q '^# Off-site backups' "$ENV_FILE" || \
    printf '\n# Off-site backups. The destination holds ciphertext only - see host/offsite-sync.sh.\n' >> "$ENV_FILE"
add OFFSITE_ENDPOINT   "$ENDPOINT"
add OFFSITE_BUCKET     "$BUCKET"
add OFFSITE_ACCESS_KEY "$KEY"
add OFFSITE_SECRET_KEY "$SECRET"
add OFFSITE_REGION     "$REGION"

echo
echo "=== 2. the encryption passphrase ==="
if grep -q '^BACKUP_PASSPHRASE=' "$ENV_FILE"; then
    echo "    already set - leaving it alone, and assuming you still have a copy elsewhere"
else
    PASS=$(head -c 48 /dev/urandom | base64 | tr -d '/+=' | head -c 44)
    printf 'BACKUP_PASSPHRASE=%s\n' "$PASS" >> "$ENV_FILE"
    cat <<BANNER

    ############################################################################
    #  Copy this into a password manager NOW. It is printed once.              #
    #                                                                          #
    #  $PASS
    #                                                                          #
    #  Everything sent off-site is encrypted under it. Kept only on this        #
    #  machine, it is worthless: losing the machine is the case backups exist   #
    #  for, and the passphrase would go with it.                                #
    ############################################################################

BANNER
    read -r -p "    Type 'saved' once it is in your password manager: " ack
    [ "$ack" = "saved" ] || { echo "    Not saved - stopping. Nothing has been scheduled." >&2; exit 1; }
fi
chown "$OWNER": "$ENV_FILE"; chmod 600 "$ENV_FILE"

echo
echo "=== 3. systemd wiring ==="
install -m 0644 "$DEPLOY/host/systemd/offsite-sync.service" /etc/systemd/system/offsite-sync.service
install -d /etc/systemd/system/event-ticket-backup.service.d
install -m 0644 "$DEPLOY/host/systemd/offsite-on-backup.conf" \
    /etc/systemd/system/event-ticket-backup.service.d/offsite.conf
systemctl daemon-reload
echo "    offsite-sync.service runs when event-ticket-backup.service succeeds"

echo
echo "=== 4. proving it, now, rather than at 03:00 ==="
sudo -u "$OWNER" "$DEPLOY/host/offsite-sync.sh"

echo
cat <<'TEXT'
=== from here on ===
  It runs after each nightly backup succeeds, and only then - there is nothing worth shipping
  until a backup has been taken AND restored into a scratch database.

  systemctl status offsite-sync      the last run
  journalctl -u offsite-sync -n 40   the history

  To restore from it, on any machine:

      gpg --decrypt <name>.tar.gz.gpg | tar -xzf -
      pg_restore -d eventticket <name>/eventticket.dump

  The archive also carries .env, so TICKET_CODE_KEY comes back with it. Without that key every
  outstanding ticket is unverifiable - a full house at the door and no way to admit anyone.
TEXT
