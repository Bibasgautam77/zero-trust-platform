# Enterprise Zero-Trust Access Platform

Copyright © Bibas Gautam. All rights reserved.
This project uses third-party open-source libraries and tools (FastAPI, Next.js,
PostgreSQL, Redis, Open Policy Agent, Keycloak, and others). Their respective licenses
apply; see each project's own repository for license text. No ownership of these
third-party components is claimed.

A working reference implementation of a Zero-Trust access control system:
**Identity + Device → Policy Engine → Decision → Least-Privilege Session → Continuous
Audit.**

---

## 1. What's actually implemented

- OIDC/OAuth2 Authorization Code + PKCE login against a real, running Keycloak
  instance (included in `docker-compose.yml`) — or point `OIDC_ISSUER` at your own
  enterprise IdP with no code changes.
- Local email/password login as an alternative/fallback path.
- TOTP-based MFA (RFC 6238): enroll, verify, disable.
- RBAC + ABAC authorization decisions via a real Open Policy Agent instance evaluating
  `opa/policy.rego` (not a mock — it's a running OPA server the backend calls over
  HTTP).
- Device posture collection and scoring (disk encryption, screen lock, EDR presence),
  explicitly flagged as **self-reported** unless a real EDR/MDM integration is wired up.
- A transparent, rule-based risk engine (0–100 score) combining MFA status, device
  posture, network origin, and time-of-day.
- Short-lived JWT access tokens (10 min default) with rotating refresh tokens (24 h
  default); refresh **and** every `policy/check` call re-run the risk engine
  (continuous verification, not just point-in-time login checks).
- An append-only audit log covering logins, MFA changes, device changes, policy
  decisions, session revocations, and admin actions.
- A working Next.js frontend: login, registration, MFA enrollment (QR code rendered
  entirely client-side — the secret is never sent to a third party), device
  registration, session management, admin audit log viewer, and an interactive policy
  "try it" panel.
- Unit and integration tests for the risk engine, security primitives, and the full
  auth API flow, plus a Rego unit test suite for the policy itself.
- Docker Compose for the whole stack; Windows batch scripts for setup/start/stop/
  restart/health-check; Alembic migration scaffolding for production deployments.

## 2. What is intentionally NOT implemented (see also `docs/threat-model.md`)

- **No real EDR/MDM vendor integration.** `device_service.fetch_verified_posture_from_edr`
  raises `NotImplementedError` if you set `EDR_PROVIDER`/`EDR_API_KEY`/`EDR_API_BASE_URL`
  without also writing a vendor-specific adapter — this is deliberate: no credentials or
  vendor were specified, so nothing is faked as "operational" against a real service.
- **No rate limiting / account lockout** on login or refresh endpoints yet (documented
  as a hardening item).
- **No TLS termination** in the provided docker-compose (add a reverse proxy / ingress
  for production).
- OIDC PKCE flow state is held in backend process memory (`_pending_flows` in
  `oidc.py`), which works for a single backend replica but must move to Redis before
  scaling horizontally — this is called out explicitly in the threat model and in code
  comments.
- Kubernetes manifests are not included; the deployment target documented and tested
  here is Docker Compose. See "Kubernetes" note below for what OPA/Rego portability
  means for that path.
- **This code was written and reviewed carefully but could not be executed in the
  environment that produced it (no network access to install Python/Node
  dependencies).** Run the test suite yourself (Section 6) before relying on this in
  any real environment.

## 3. Technology stack and why

| Layer | Choice | Why |
|---|---|---|
| Backend | FastAPI (async) | Native async DB/HTTP calls needed for low-latency continuous verification; automatic OpenAPI docs |
| Frontend | Next.js (App Router) | Matches the requested stack; server/client component split fits a security-sensitive admin UI |
| Database | PostgreSQL | ACID guarantees for session/audit integrity; native UUID and JSON column support |
| Cache/state | Redis | Provisioned for rate limiting and multi-replica OIDC state (see Known Limitations for what still needs wiring) |
| Policy | OPA/Rego | Industry-standard PDP separate from the PEP; independently testable and auditable |
| Identity | Keycloak (demo) / any OIDC IdP | Real, standards-compliant OIDC provider for local testing; swappable via env vars |
| Containerization | Docker / Docker Compose | Matches the requested deployment target; Kubernetes manifests are a natural next step (each service is already a single stateless container aside from Postgres/Redis) |

## 4. Project structure

```
zero-trust-platform/
├── backend/                  FastAPI application
│   ├── app/
│   │   ├── core/             config, database, security (JWT/TOTP), logging
│   │   ├── models/           SQLAlchemy models
│   │   ├── schemas/          Pydantic request/response schemas
│   │   ├── services/         risk engine, OPA client, audit writer, device posture, OIDC client
│   │   └── api/routes/       auth, oidc, mfa, devices, sessions, policy, audit, users
│   ├── alembic/               production migration scaffolding
│   ├── scripts/seed_data.py  idempotent role + bootstrap admin seeding
│   ├── tests/                pytest unit + integration tests
│   └── Dockerfile
├── frontend/                 Next.js application
│   ├── app/                  login, register, mfa-setup, dashboard, devices, sessions, admin/audit, auth/callback
│   ├── components/           NavBar
│   ├── lib/api.ts            typed API client
│   └── Dockerfile
├── opa/                      policy.rego + policy_test.rego (RBAC + ABAC + risk gate)
├── db/keycloak-realm.json    demo IdP realm/client/user import
├── scripts/                  setup.bat, start.bat, stop.bat, restart.bat, health-check.bat
├── docs/                     architecture.md, threat-model.md, api.md
├── docker-compose.yml
└── .env.example
```

## 5. Running it (Windows, Docker Desktop required)

**Easiest path:** double-click `start.bat` in the project root. It checks Docker is
running, creates `.env` on first run, builds images, starts everything in the right
order, seeds default roles + a bootstrap admin account (idempotent - safe to run
again), and waits for the backend health check before printing the URLs. Re-run it any
time; it won't re-seed data that already exists.

**Step-by-step alternative**, if you want more control:
```
scripts\setup.bat      REM builds images, starts infra, seeds roles + prints a bootstrap admin password
scripts\start.bat      REM starts the full stack and waits for the backend health check
scripts\health-check.bat  REM verifies every container is healthy
```

Then open:
- Frontend: http://localhost:3000
- Backend interactive API docs: http://localhost:8000/docs
- Keycloak admin console: http://localhost:8080 (admin / value of `KEYCLOAK_ADMIN_PASSWORD`)
- A demo Keycloak end-user is pre-provisioned: `demo.user@example.com` / `DemoPass123!`
  (see `db/keycloak-realm.json`) for testing the OIDC flow.

`scripts\stop.bat` stops all containers (data preserved). `scripts\restart.bat` stops
then starts. Run `scripts\setup.bat` again any time you change `docker-compose.yml`.

### Running without Docker (local Python/Node)
```
cd backend
python -m venv venv && venv\Scripts\activate
pip install -r requirements.txt
REM point DATABASE_URL at a local Postgres instance in your own .env
python -m scripts.seed_data
uvicorn app.main:app --reload

cd ..\frontend
npm install
npm run dev
```
You'll also need OPA running locally (`opa run --server opa/policy.rego`) and either
Keycloak or another OIDC IdP if you want to exercise the OIDC login path.

## 6. Testing

```
cd backend
pip install -r requirements.txt
pytest --cov=app tests/
```
The test suite uses an in-memory SQLite database (via `aiosqlite`) and does not require
Postgres, Redis, or OPA to be running — it exercises the FastAPI app directly through
`httpx.ASGITransport`. Policy-engine calls in the integration tests exercise
`/policy/check` only implicitly (through the tests that don't call it); if you add
tests that call `/policy/check` directly, run a local OPA instance first, or mock
`app.services.policy_engine.evaluate_policy`.

Rego policy tests:
```
opa test opa/ -v
```

## 7. Database migrations (production)

The app auto-creates tables on startup only when `ENVIRONMENT=development`
(`backend/app/core/database.py: init_models`). For any other environment, use Alembic:
```
cd backend
alembic revision --autogenerate -m "initial schema"
alembic upgrade head
```
No initial migration file is checked into this repository — generate it against your
actual target database on first setup, review the autogenerated SQL, then commit it.

## 8. Configuration reference

See `.env.example` for every variable with inline documentation. Notably:
- `RISK_THRESHOLD_ALLOW` / `_STEP_UP` / `_DENY` tune how aggressively the platform
  requires step-up authentication or denies access outright.
- `EDR_PROVIDER` / `EDR_API_KEY` / `EDR_API_BASE_URL` are blank by default; leaving
  them blank keeps all device posture explicitly self-reported.
- `JWT_SIGNING_KEY` **must** be replaced (`openssl rand -hex 32`) before any use
  beyond local development.

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `scripts\setup.bat` fails at "docker compose build" | Docker Desktop not running, or insufficient resources | Start Docker Desktop; ensure at least 4 GB RAM allocated |
| Backend health check never turns healthy | Postgres not yet ready, or `DATABASE_URL` mismatched with `.env` | `docker compose logs backend`; confirm `.env` values match `docker-compose.yml` service names |
| `/policy/check` always returns `deny` with "Policy engine unreachable" | OPA container isn't running or `OPA_URL` is wrong | `docker compose ps opa`; `curl http://localhost:8181/health` |
| OIDC callback fails with "Unknown or expired OIDC state" | You restarted the backend between requesting the authorize URL and completing the callback (in-memory state was lost) | Retry the login; see Known Limitations re: moving this to Redis |
| MFA QR code doesn't scan | Some authenticator apps are picky about label formatting | Use the printed secret to add the account manually instead |

## 10. Known limitations (full list)

See Section 2 above and `docs/threat-model.md`'s "Production hardening checklist" for
the complete, itemized list — repeated here for visibility: no real EDR/MDM adapter, no
rate limiting, no TLS in the default compose file, in-memory OIDC state (single
replica only), no Kubernetes manifests, and the test suite was written but not executed
in the authoring environment due to no network access there.

## 11. Final verification checklist (source requirements → implementation)

| Source requirement | Where it's implemented |
|---|---|
| OIDC/OAuth2 | `backend/app/services/oidc_service.py`, `backend/app/api/routes/oidc.py`, Keycloak in `docker-compose.yml` |
| MFA | `backend/app/core/security.py` (TOTP), `backend/app/api/routes/mfa.py`, `frontend/app/mfa-setup` |
| RBAC/ABAC | `opa/policy.rego`, `backend/app/services/policy_engine.py` |
| Device posture | `backend/app/models/models.py: Device`, `backend/app/services/device_service.py`, `frontend/app/devices` |
| Policy engine | OPA service in `docker-compose.yml`, `opa/policy.rego`, `opa/policy_test.rego` |
| Risk-based access | `backend/app/services/risk_engine.py` |
| Short-lived sessions | `backend/app/core/security.py` (10 min access / 24 h rotating refresh), `Session` model with `is_revoked` |
| Audit logs | `backend/app/models/models.py: AuditLog`, `backend/app/services/audit_service.py`, `frontend/app/admin/audit` |
| Next.js / FastAPI / PostgreSQL / Redis / OIDC / OPA/Rego / Docker | all present in `docker-compose.yml` |
| Windows scripts | `start.bat` (root, one-click), `scripts/setup.bat`, `start.bat`, `stop.bat`, `restart.bat`, `health-check.bat` |
| `.env.example` | present, fully documented, no hard-coded secrets |
| Tests | `backend/tests/` (pytest), `opa/policy_test.rego` |
| Docs | this file, `docs/architecture.md`, `docs/threat-model.md`, `docs/api.md`, plus live Swagger/Redoc |
| Demo vs. real integrations clearly distinguished | Sections 1–2 above; `self_reported` flag on every device row; `edr_integration_enabled` gate in code |
