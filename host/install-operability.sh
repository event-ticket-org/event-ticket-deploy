#!/usr/bin/env bash
# Installs the two things that are always on: automatic restart, and a health check that asks
# the questions pg_isready cannot.
#
#   sudo host/install-operability.sh
#
# Idempotent. Changes no Postgres configuration and restarts nothing.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
VERSION=${VERSION:-18}

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }

echo "=== 1. restart a cluster that dies ==="
# A drop-in on the template unit, so it applies to every cluster including ones created later -
# a per-cluster override would silently not cover the next standby somebody builds.
install -d /etc/systemd/system/postgresql@.service.d
install -m 0644 "$HERE/systemd/postgresql-restart.conf" \
    /etc/systemd/system/postgresql@.service.d/restart.conf
systemctl daemon-reload
for c in $(pg_lsclusters -h | awk -v v="$VERSION" '$1==v {print $2}'); do
    printf '    %-16s Restart=%s\n' "$c" \
        "$(systemctl show "postgresql@$VERSION-$c" --property=Restart --value 2>/dev/null)"
done

echo
echo "=== 2. the health check, every five minutes ==="
install -m 0644 "$HERE/systemd/cluster-health.service" /etc/systemd/system/cluster-health.service
install -m 0644 "$HERE/systemd/cluster-health.timer"   /etc/systemd/system/cluster-health.timer
chmod 0755 "$HERE/cluster-health.sh"
systemctl daemon-reload
systemctl enable --now cluster-health.timer >/dev/null
echo "    next run: $(systemctl show cluster-health.timer --property=NextElapseUSecRealtime --value 2>/dev/null | cut -d. -f1)"

echo
echo "=== running it once now ==="
"$HERE/cluster-health.sh" || true

echo
cat <<'TEXT'
=== how you find out something is wrong ===
  systemctl --failed                 the check leaves a failed unit behind
  systemctl status cluster-health    the last verdict, with its output
  journalctl -u cluster-health -n 40 the history
  sudo host/cluster-health.sh        on demand

  This is deliberately not email or a pager. A check that nobody reads is the same as no check,
  and the honest first step is a check that exists and is visible where you already look. Wiring
  it to a notifier is a decision about where you want to be interrupted, not a technical one.
TEXT
