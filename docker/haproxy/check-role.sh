#!/bin/sh
#
# Answers one question about one Postgres node: is it the primary, or a standby?
#
# HAProxy runs this for every backend server it health-checks. Exit 0 means "keep this server in
# the pool"; anything else takes it out.
#
# Which answer counts as healthy depends on which front door is asking, and HAProxy says so via
# HAPROXY_PROXY_NAME - the name of the `listen` section. An environment variable could not do
# this job: both proxies live in one container and would share it.
#
#   postgres_primary  -> healthy when pg_is_in_recovery() is FALSE
#   postgres_replica  -> healthy when pg_is_in_recovery() is TRUE
#
# Why ask the node rather than trust its name: after a promotion the names lie, and nothing
# renames anything. Configuration that hardcodes a host is wrong from the moment a failover
# happens, which is exactly when being wrong is least affordable.
set -eu

# Set here, never inherited. HAProxy runs external-check commands with a sanitised environment -
# only its own HAPROXY_* variables survive - so anything set on the container simply is not
# there. That was found the direct way, twice:
#
#   check-role.sh: CHECK_PASSWORD: parameter not set
#   check-role.sh: tr: not found            (for a binary that is plainly installed)
#
# The second is PATH being sanitised too: the same lesson arriving again. Nothing about this
# script's environment can be assumed; everything it needs, it sets or reads from a file.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PGCONNECT_TIMEOUT=2
export PGPASSFILE=/etc/haproxy/pgpass

# Written by the entrypoint from the deployment's own environment, because this deployment's
# credentials are real and cannot live in a committed file. A file rather than a variable for the
# reason above: the variable would not arrive.
. /etc/haproxy/check.conf

in_recovery=$(psql \
    --host="${HAPROXY_SERVER_ADDR}" \
    --port="${HAPROXY_SERVER_PORT}" \
    --username="${CHECK_USER}" \
    --dbname=postgres \
    --quiet --tuples-only --no-align \
    --command='select pg_is_in_recovery()' 2>/dev/null)

# -qtA already yields a bare `t` or `f`, and command substitution strips the trailing newline, so
# nothing needs trimming. The first version piped through `tr`, and that is what discovered the
# empty PATH above.
#
# An unreachable node answers nothing rather than answering false. Failing closed is deliberate:
# a server nobody can query is a server nobody should be routed to.
[ -n "$in_recovery" ] || exit 1

case "${HAPROXY_PROXY_NAME}" in
    postgres_primary) [ "$in_recovery" = "f" ] && exit 0 || exit 1 ;;
    postgres_replica) [ "$in_recovery" = "t" ] && exit 0 || exit 1 ;;
    *)                exit 1 ;;
esac
