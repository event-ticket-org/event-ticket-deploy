#!/bin/sh
# Writes the health check's credentials, then hands over to HAProxy.
#
# They are written at start rather than baked into the image because this deployment's database
# password is real. The development cluster in event-ticket-backend commits a pgpass file, and
# that is safe there for the reason every value in application-dev.yml is safe: it can only ever
# be used locally. Here it cannot be committed at all.
set -eu

: "${DATABASE_USERNAME:?}" "${DATABASE_PASSWORD:?}"

# libpq refuses a password file that is group- or world-readable, and says so in a way that
# reads like an authentication failure rather than a permissions one.
umask 077
printf '*:*:postgres:%s:%s\n' "$DATABASE_USERNAME" "$DATABASE_PASSWORD" > /etc/haproxy/pgpass
printf 'CHECK_USER=%s\n' "$DATABASE_USERNAME" > /etc/haproxy/check.conf
chmod 0600 /etc/haproxy/pgpass /etc/haproxy/check.conf
chown haproxy:haproxy /etc/haproxy/pgpass /etc/haproxy/check.conf

# Drop to the haproxy user for the process that actually faces the network. Only the few lines
# above needed root, and they are done.
exec su-exec haproxy "$@"
