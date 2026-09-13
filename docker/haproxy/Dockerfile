# HAProxy that can tell a primary from a standby.
#
# The stock image cannot. HAProxy ships `option pgsql-check`, which opens a connection and sends
# a startup packet - it proves a server is alive and says nothing about whether it accepts
# writes. That distinction is the entire reason this proxy exists, so the image needs a Postgres
# client and a script that asks the server directly.
FROM haproxy:3.0-alpine

USER root
# postgresql-client rather than a pinned major: this is libpq asking one question of a server
# whose major version is the deployment's business, not the proxy's. su-exec is how the
# entrypoint drops back to the haproxy user after writing the credential files.
RUN apk add --no-cache postgresql-client su-exec

# The image keeps its configuration under /usr/local/etc/haproxy and has no /etc/haproxy at all.
# The development cluster's Dockerfile COPYs a pgpass file there, which creates the directory as
# a side effect; this one writes the file at runtime instead, so the directory has to exist
# first. The failure without it is `can't create /etc/haproxy/pgpass: nonexistent directory`, in
# a crash loop.
RUN mkdir -p /etc/haproxy && chown haproxy:haproxy /etc/haproxy && chmod 0750 /etc/haproxy

COPY check-role.sh /usr/local/bin/check-role.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/check-role.sh /usr/local/bin/entrypoint.sh

# Root, deliberately, and only as far as the entrypoint: it writes the password file and then
# execs HAProxy as the haproxy user.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["haproxy", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
