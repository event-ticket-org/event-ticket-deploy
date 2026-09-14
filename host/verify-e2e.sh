#!/usr/bin/env bash
# The whole flow, against the live deployment, through the public hostname.
#
#   host/verify-e2e.sh
#
# Not against localhost and not against the container network: the point is to exercise what a
# person actually reaches - Cloudflare, the frontend's nginx, the backend, HAProxy, the primary
# and the replica - and any of those can be the thing that is broken.
set -uo pipefail
cd /opt/event-ticket/event-ticket-deploy
set -a; . ./.env; set +a

B=https://tickets.aibles-java.site/api/v1
S=$(date +%s)
PW='Password123!'
# Cloudflare's bot protection answers a default curl or python agent with 1010, which looks
# exactly like the application refusing the request. Found the hard way.
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %-46s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %-46s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" "$2" || no "$1" "got '$2', want '$3'"; }

c() { curl -s -A "$UA" --max-time 25 "$@"; }
code() { curl -s -o /dev/null -w '%{http_code}' -A "$UA" --max-time 25 "$@"; }
j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval('d'+'''$1'''))" 2>/dev/null; }
# Separate from j(), which prepends `d` - so j "[len(d['items'])]" evaluates as
# d[len(d['items'])] and raises, and the helper's 2>/dev/null turns that into an empty string.
count() { python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d['items']) if isinstance(d, dict) and 'items' in d else len(d))" 2>/dev/null; }
sql() { PGPASSWORD="$DATABASE_PASSWORD" psql -h 127.0.0.1 -p 5433 -U "$DATABASE_USERNAME" -d "$DATABASE_NAME" -tAc "$1" 2>/dev/null | tr -d '\r'; }

# Registers, reads the verification token out of the outbox, and returns an access token.
signup() {
    local email=$1 name=$2
    c -o /dev/null -X POST "$B/auth/register" -H 'Content-Type: application/json' \
      -d "{\"email\":\"$email\",\"password\":\"$PW\",\"displayName\":\"$name\"}"
    # Poll rather than sleep once. A fixed second was enough most of the time and not all of it,
    # and the failure was invisible at the point it happened: an empty token produces
    # "Authorization: Bearer " on every later call, so the run reports 401 on whatever it tried
    # next and looks like a broken deployment.
    local vt=""
    for _ in $(seq 1 20); do
        vt=$(sql "select body from email_delivery where recipient='$email' order by created_at desc limit 1" \
             | grep -oE 'token=[A-Za-z0-9_.-]+' | head -1 | cut -d= -f2)
        [ -n "$vt" ] && break
        sleep 1
    done
    [ -n "$vt" ] || { echo ""; return; }
    c -X POST "$B/auth/verify-email" -H 'Content-Type: application/json' \
      -d "{\"token\":\"$vt\"}" | j "['accessToken']"
}

echo "=== 1. the public surface ==="
check "the app answers"            "$(code https://tickets.aibles-java.site/)" 200
check "the public listing answers" "$(code "$B/public/events")" 200

echo
echo "=== 2. identity ==="
ORG_EMAIL="e2e-org-$S@example.com"; BUY_EMAIL="e2e-buy-$S@example.com"
ORG_TOK=$(signup "$ORG_EMAIL" "E2E Organizer")
BUY_TOK=$(signup "$BUY_EMAIL" "E2E Buyer")
[ -n "$ORG_TOK" ] && ok "organizer registered and verified" || no "organizer registered and verified"
[ -n "$BUY_TOK" ] && ok "buyer registered and verified"     || no "buyer registered and verified"
[ -n "$ORG_TOK" ] || exit 1

echo
echo "=== 3. organization, approved by the platform ==="
ORG=$(c -X POST "$B/organizations" -H "Authorization: Bearer $ORG_TOK" -H 'Content-Type: application/json' \
      -d "{\"name\":\"E2E Org $S\"}" | j "['id']")
[ -n "$ORG" ] && ok "organization created" "${ORG:0:8}" || no "organization created"
sql "update organization set status='APPROVED' where id='$ORG'" >/dev/null
ORG_TOK=$(c -X POST "$B/auth/switch-organization" -H "Authorization: Bearer $ORG_TOK" \
          -H 'Content-Type: application/json' -d "{\"organizationId\":\"$ORG\"}" | j "['accessToken']")
[ -n "$ORG_TOK" ] && ok "switched into the organization" || no "switched into the organization"

echo
echo "=== 4. venue and seat map ==="
VEN=$(c -X POST "$B/venues" -H "Authorization: Bearer $ORG_TOK" -H 'Content-Type: application/json' \
      -d '{"name":"E2E Hall","city":"Ha Noi","timezone":"Asia/Ho_Chi_Minh"}' | j "['id']")
[ -n "$VEN" ] && ok "venue created" "${VEN:0:8}" || no "venue created"

SEATS=$(python3 -c "
import json
seats=[{'label':f'A{i}','x':float(i*10),'y':0.0,'tierName':'Standard'} for i in range(1,7)]
print(json.dumps({'seats':seats,'elements':[]}))")
check "seat map accepted" \
  "$(code -X PUT "$B/venues/$VEN/seat-map" -H "Authorization: Bearer $ORG_TOK" \
      -H 'Content-Type: application/json' -d "$SEATS")" 200

echo
echo "=== 5. event, pricing, publish ==="
# doorsOpenAt and endsAt are not optional at publish time, and the refusal says why: the door
# needs them to tell someone who is early from someone who is late. The first version of this
# script omitted them and read the resulting 409 as a broken deployment.
# Tonight, not in forty days. The door refuses a ticket for an event whose doors have not
# opened - correctly, with EVENT_NOT_OPEN - so an E2E that means to reach the scanner has to
# create an event that is actually happening. Doors already open, starts shortly, ends later.
STARTS=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)
DOORS=$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)
ENDS=$(date -u -d '+5 hours' +%Y-%m-%dT%H:%M:%SZ)
EV=$(c -X POST "$B/events" -H "Authorization: Bearer $ORG_TOK" -H 'Content-Type: application/json' \
     -d "{\"venueId\":\"$VEN\",\"title\":\"E2E Night $S\",\"startsAt\":\"$STARTS\",\"doorsOpenAt\":\"$DOORS\",\"endsAt\":\"$ENDS\",\"listed\":false}" | j "['id']")
[ -n "$EV" ] && ok "event created" "${EV:0:8}" || no "event created"

check "pricing tiers set" \
  "$(code -X PUT "$B/events/$EV/pricing-tiers" -H "Authorization: Bearer $ORG_TOK" \
      -H 'Content-Type: application/json' \
      -d '[{"name":"Standard","price":{"amount":250000,"currency":"VND"}}]')" 200
check "event published" \
  "$(code -X POST "$B/events/$EV/publish" -H "Authorization: Bearer $ORG_TOK")" 200

echo
echo "=== 6. what a stranger sees (this is the replica's job) ==="
sleep 2
# Unlisted, so it must NOT be on the front page - and must still be reachable by its own URL,
# which is what a shared link is. Both halves matter: the first keeps verification runs out of
# the public listing, the second still exercises the anonymous read path that the replica serves.
check "an unlisted event stays off the public listing" \
  "$(c "$B/public/events?q=E2E+Night+$S" | count)" 0
check "but is reachable by its own link" \
  "$(code "$B/public/events/$EV")" 200
SEATMAP=$(c "$B/public/events/$EV/seat-map")
SEAT=$(echo "$SEATMAP" | j "['seats'][0]['id']")
[ -n "$SEAT" ] && ok "public seat map readable" "seat ${SEAT:0:8}" || no "public seat map readable"

echo
echo "=== 7. checkout, and the money ==="
ORDER=$(c -X POST "$B/checkout" -H "Authorization: Bearer $BUY_TOK" -H 'Content-Type: application/json' \
        -d "{\"eventId\":\"$EV\",\"seatIds\":[\"$SEAT\"]}" | j "['id']")
[ -n "$ORDER" ] && ok "order created, seat held" "${ORDER:0:8}" || no "order created, seat held"
# AWAITING_PAYMENT, not PENDING_PAYMENT. The contract's OrderStatus enum is the authority and
# the first version of this script invented a neighbouring word.
check "order starts unpaid" "$(c "$B/orders/$ORDER" -H "Authorization: Bearer $BUY_TOK" | j "['status']")" AWAITING_PAYMENT

check "payment session started" \
  "$(code -X POST "$B/orders/$ORDER/payment-sessions" -H "Authorization: Bearer $BUY_TOK" \
      -H 'Content-Type: application/json' -d '{"provider":"FAKE"}')" 201

REF=$(sql "select provider_ref from payment_session where order_id='$ORDER' order by created_at desc limit 1" | head -1 | xargs)
DELIVERY=$(cat /proc/sys/kernel/random/uuid)
BODY=$(printf '{"eventId":"%s","providerRef":"%s","status":"PAID"}' "$DELIVERY" "$REF")
# Signed over the raw bytes, as a real provider would. A body parsed and re-serialised has a
# different signature, and that mismatch only shows up against something that actually verifies.
SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$FAKE_PAYMENT_SECRET" -hex | sed 's/^.*= //')
check "webhook accepted" \
  "$(code -X POST "$B/webhooks/payments/FAKE" -H 'Content-Type: application/json' \
      -H "x-signature: $SIG" -d "$BODY")" 204

sleep 2
check "order is paid" "$(c "$B/orders/$ORDER" -H "Authorization: Bearer $BUY_TOK" | j "['status']")" PAID

# Criterion 4: the same delivery twice produces one paid order and one set of tickets.
code -X POST "$B/webhooks/payments/FAKE" -H 'Content-Type: application/json' \
    -H "x-signature: $SIG" -d "$BODY" >/dev/null
check "a repeated delivery issues no second ticket" \
  "$(sql "select count(*) from ticket t join ticket_order o on o.id=t.order_id where o.id='$ORDER'")" 1

echo
echo "=== 8. the door ==="
# `ticketCode`, not `code` - and it is the one field never logged or stored, because a ticket
# code is a random lookup plus a MAC and the code itself lives only in the buyer's hands.
CODE=$(c "$B/orders/$ORDER/tickets" -H "Authorization: Bearer $BUY_TOK" | j "[0]['ticketCode']")
[ -n "$CODE" ] && ok "ticket issued" || no "ticket issued"
# `outcome`, and a refusal is a 200 with a reason rather than an HTTP error - a client renders
# an error as "something went wrong", which is the one message that helps nobody at a gate with
# a queue.
check "first scan admits" \
  "$(c -X POST "$B/events/$EV/scans" -H "Authorization: Bearer $ORG_TOK" -H 'Content-Type: application/json' \
      -d "{\"ticketCode\":\"$CODE\",\"deviceId\":\"e2e-door\"}" | j "['outcome']")" ADMITTED
check "second scan refuses" \
  "$(c -X POST "$B/events/$EV/scans" -H "Authorization: Bearer $ORG_TOK" -H 'Content-Type: application/json' \
      -d "{\"ticketCode\":\"$CODE\",\"deviceId\":\"e2e-door\"}" | j "['outcome']")" ALREADY_REDEEMED

echo
echo "=== 9. did the cluster actually do the work? ==="
for p in 5433 5434; do
    n=$(PGPASSWORD="$DATABASE_PASSWORD" psql -h 127.0.0.1 -p $p -U "$DATABASE_USERNAME" -d "$DATABASE_NAME" \
        -tAc "select count(*) from pg_stat_activity where datname=current_database() and backend_type='client backend'" 2>/dev/null | tr -d '\r')
    case $p in 5433) l="primary  5433";; 5434) l="standby1 5434";; esac
    printf '  %-52s %s connections\n' "$l" "$n"
done
printf '  %-52s %s\n' "the order really is on the primary" "$(sql "select status from ticket_order where id='$ORDER'")"
printf '  %-52s %s\n' "and replicated to the standby" \
  "$(PGPASSWORD=$DATABASE_PASSWORD psql -h 127.0.0.1 -p 5434 -U "$DATABASE_USERNAME" -d "$DATABASE_NAME" -tAc "select status from ticket_order where id='$ORDER'" 2>/dev/null | tr -d '\r')"

echo
echo "=== cleaning up after itself ==="
# A run that leaves organizations, events and orders behind in a live database is a run nobody
# wants to repeat. Scoped to the ids this run created, not to a name pattern.
# One delete, not eleven. organization_id is ON DELETE CASCADE on every tenant-scoped table, so
# this takes the event, its seats and tiers, the order and its seats, the payment session and its
# events, the ticket, the scan, the membership, the venue and the audit entries with it.
#
# The first version of this spelled out the chain by hand, got payment_event.session_id wrong,
# and rolled the whole transaction back - cleaning up nothing while reporting nothing.
sql "delete from organization where id='$ORG'" >/dev/null
# Users belong to no organization, so they do not cascade and are named separately.
sql "delete from email_delivery where recipient in ('$ORG_EMAIL','$BUY_EMAIL')" >/dev/null
sql "delete from app_user where email in ('$ORG_EMAIL','$BUY_EMAIL')" >/dev/null

check "its organization is gone again" \
  "$(sql "select count(*) from organization where id='$ORG'")" 0
check "and its event with it"           \
  "$(sql "select count(*) from event where id='$EV'")" 0
check "and its order"                   \
  "$(sql "select count(*) from ticket_order where id='$ORDER'")" 0
check "and both accounts"               \
  "$(sql "select count(*) from app_user where email in ('$ORG_EMAIL','$BUY_EMAIL')")" 0

echo
echo "=== $pass passed, $fail failed ==="
exit $(( fail > 0 ))
