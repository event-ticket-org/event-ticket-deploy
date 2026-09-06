#!/usr/bin/env bash
#
# Builds both images and, the first time, writes a .env with secrets nobody has to invent.
#
# The one thing this script knows that compose.yaml does not is where the source lives. That
# is deliberate: compose.yaml refers to images by tag and so reads the same whether they came
# from here or from a registry, and the assumption about a working copy is confined to two
# variables that can be overridden.

set -euo pipefail
cd "$(dirname "$0")"

BACKEND_REPO=${BACKEND_REPO:-../event-ticket-backend}
FRONTEND_REPO=${FRONTEND_REPO:-../event-ticket-frontend}

# A secret nobody chose and nobody has to remember. openssl is on macOS and on every Linux
# that runs Docker; base64 rather than hex so the same entropy is fewer characters.
secret() { openssl rand -base64 36 | tr -d '\n/+=' | cut -c1-48; }

if [[ ! -f .env ]]; then
    echo "==> writing .env with generated secrets"
    cp env.example .env
    # In place, per key, so the comments in env.example survive into .env - they are most of
    # what the file is for. A BSD sed needs the empty argument to -i and a GNU sed refuses it,
    # which is why this writes through a temporary file instead.
    for key in DATABASE_PASSWORD JWT_SECRET TICKET_CODE_KEY FAKE_PAYMENT_SECRET \
               STORAGE_SECRET_KEY; do
        value=$(secret)
        awk -v k="$key" -v v="$value" \
            'index($0, k "=") == 1 { print k "=" v; next } { print }' .env > .env.tmp
        mv .env.tmp .env
    done
    echo "    .env written. It is gitignored, and PLATFORM_ADMIN_EMAILS is still empty -"
    echo "    set it to your own address before the first sign-up if you want the admin queue."
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

echo "==> backend image ${BACKEND_IMAGE} from ${BACKEND_REPO}"
docker build -t "${BACKEND_IMAGE}" "${BACKEND_REPO}"

# The provider is compiled into the bundle, so it is an argument here rather than an
# environment variable in compose.yaml. See the frontend Dockerfile for why that is the
# honest arrangement and not a limitation to engineer around.
echo "==> frontend image ${FRONTEND_IMAGE} from ${FRONTEND_REPO} (${VITE_PAYMENT_PROVIDER})"
docker build -t "${FRONTEND_IMAGE}" \
    --build-arg "VITE_PAYMENT_PROVIDER=${VITE_PAYMENT_PROVIDER}" \
    "${FRONTEND_REPO}"

echo
echo "Built. Start it with:  docker compose up -d"
echo "Then open:             http://localhost:${APP_PORT}"
