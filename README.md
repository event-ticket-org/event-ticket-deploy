# event-ticket-deploy

Runs the whole product as containers: Postgres, SeaweedFS, the backend and the frontend behind one
origin.

```bash
git clone https://github.com/event-ticket-org/event-ticket-backend.git
git clone https://github.com/event-ticket-org/event-ticket-frontend.git
git clone https://github.com/event-ticket-org/event-ticket-deploy.git
cd event-ticket-deploy
./build.sh          # builds both images, and writes .env with generated secrets
docker compose up -d
open http://localhost:8081
```

`build.sh` expects the other two repositories beside this one. Override with `BACKEND_REPO` and
`FRONTEND_REPO`, or skip it entirely and set `BACKEND_IMAGE` / `FRONTEND_IMAGE` in `.env` to
images from a registry — `compose.yaml` only ever refers to tags.

## What this is not

It is not the development stack. `event-ticket-backend/compose.yaml` starts the two things a
developer needs *behind* a locally-run application, and that is still how you work on the code:

```bash
docker compose up -d && ./mvnw spring-boot:run    # in event-ticket-backend
npm run dev                                       # in event-ticket-frontend
```

The two publish some of the same ports, so run one or the other.

## The shape of a deployment

Four things are true here that are not true on a laptop, and each of them was a bug before it
was a line of configuration.

**One origin.** nginx serves the built client and proxies `/api` to the backend, so the browser
sees a single host. That is not a convenience: `src/api/client.ts` asks for `/api/v1` relative
to wherever it was served and never learns a backend address, which is what keeps CORS out of
the system entirely. The backend is not published at all.

**The object store has three addresses.** They are the same string on a laptop and stop being
it the moment the backend runs in a container:

| | who uses it | why it is separate |
|---|---|---|
| `STORAGE_ENDPOINT` | the backend's SDK | `seaweedfs:9000` — a name only the container network resolves |
| `STORAGE_UPLOAD_BASE_URL` | the browser, posting a cover | must be reachable from outside Docker |
| `STORAGE_PUBLIC_BASE_URL` | the browser, fetching a cover | may be a CDN, which can serve a picture and cannot accept one |

A presigned POST policy signs the policy document rather than the host, so the same signature
is valid at any address that reaches the same bucket.

**Every emailed link is built from `APP_BASE_URL`.** Address verification, a ticket, a refund
notice. Change the port after people hold tickets and their links break.

**No credential has a default.** `application.yml` names them with no fallback, so a container
started without `JWT_SECRET`, `TICKET_CODE_KEY`, `DATABASE_PASSWORD`, `STORAGE_SECRET_KEY` or
`FAKE_PAYMENT_SECRET` refuses to boot. That is deliberate and it is the arrangement where
forgetting is safe: the development values live in the backend's `dev` profile, which this
image does not have. `TICKET_CODE_KEY` is the heavy one — nothing that grants entry is stored,
so a leaked database is not a set of working tickets, and that key is what makes it true.

`./build.sh` generates all five the first time. They are in `.env`, which is gitignored;
`env.example` is the readable copy and holds no values.

## Payment

`VITE_PAYMENT_PROVIDER` is compiled into the client, because `import.meta.env` is replaced at
build time — so changing it means `./build.sh` again, not an environment variable. `FAKE` is
the default and needs nothing. `STRIPE` needs `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`
in `.env`; empty means there is no Stripe provider at all, rather than one that fails on first
use.

Neither half of the money can be completed from a browser, by design: an order becomes paid
only on a provider's webhook and a refund settles only on one. On a laptop nothing sends those,
so the backend's `scripts/confirm-payment.sh` and `scripts/confirm-refund.sh` act as the
provider. They work against this stack unchanged:

```bash
BASE=http://localhost:8081/api/v1 \
PG_CONTAINER=event-ticket-postgres-1 \
FAKE_PAYMENT_SECRET=$(grep '^FAKE_PAYMENT_SECRET=' .env | cut -d= -f2) \
  ../event-ticket-backend/scripts/confirm-payment.sh <order-id>
```

## The first administrator

Set `PLATFORM_ADMIN_EMAILS` in `.env` before the first sign-up. An account named there is
promoted when it registers, and at start-up if it registered already. It is the only way to
become a platform admin and the only privilege no request can grant — approving organizations
decides who may sell tickets at all, so conferring it needs access to the deployment rather
than to the product. With it empty, no organization can ever be approved and nothing can be
published.

## What is missing

This runs the product; it does not operate it. There is no TLS, no backups, no log shipping,
no secret store, and `nfr.md`'s single instance is taken literally — admission rate limiting is
per process, so a second backend would double the limit rather than share it.
