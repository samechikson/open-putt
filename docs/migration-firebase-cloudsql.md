# Migration runbook: Supabase → Firebase Auth + Cloud SQL

This is the operator runbook for cutting the app over from Supabase (Postgres +
Auth) to **Firebase Auth** + **Cloud SQL (Postgres)**, both in the GCP project
`putting-gate`. The application code is already migrated on branch
`migrate-supabase-to-firebase`; the steps below are the infra + data work that
must be done in your GCP/Firebase account, ending in an atomic cutover.

> ⚠️ **Do not merge the branch to `main` until steps 1–6 are done and the
> `VITE_FIREBASE_*` repo variables are set.** The CI workflow auto-deploys the
> frontend on push to `main`, and the new frontend requires the Firebase config
> and a working Firebase-auth backend, or the live site breaks.

Config used throughout: project `putting-gate`, region `us-central1`, Cloud SQL
instance `putting-gate-db`, database `putting_gate`, DB user `app`.

---

## 1. Provision Cloud SQL (Postgres)

```bash
gcloud config set project putting-gate
gcloud services enable sqladmin.googleapis.com

gcloud sql instances create putting-gate-db \
  --database-version=POSTGRES_16 --region=us-central1 \
  --tier=db-f1-micro --storage-size=10GB --storage-auto-increase

gcloud sql databases create putting_gate --instance=putting-gate-db

# App DB user. Save the password — it goes into Secret Manager (step 4) and
# backend/.env (as DB_PASSWORD) for the deploy script.
DB_PASSWORD="$(openssl rand -base64 24)"
gcloud sql users create app --instance=putting-gate-db --password="$DB_PASSWORD"
echo "DB_PASSWORD=$DB_PASSWORD"
```

## 2. Apply the schema

```bash
# Simplest: connect via the Cloud SQL Auth Proxy or `gcloud sql connect`, then:
gcloud sql connect putting-gate-db --user=app --database=putting_gate \
  < backend/db/schema.sql
```

## 3. Enable Firebase Auth + register apps

In the [Firebase console](https://console.firebase.google.com/project/putting-gate):
1. **Authentication → Sign-in method → Email/Password → Enable.**
2. **Project settings → Your apps → Add app → Web.** Copy the config values
   (`apiKey`, `authDomain`, `projectId`, `appId`, `storageBucket`,
   `messagingSenderId`).
3. **Add app → iOS**, bundle id matching the Xcode target. Download
   `GoogleService-Info.plist`.

## 4. Wire secrets + deploy config

Put the DB password in `backend/.env` (read by the deploy script) — replacing the
old `SUPABASE_*` entries:

```
DB_PASSWORD=<the password from step 1>
```

The runtime env (Cloud SQL socket, `FIREBASE_PROJECT_ID`, secrets) is set by
`backend/deploy/cloud-run.sh`, already updated for this migration. It grants the
runtime SA `roles/cloudsql.client`, mounts the instance via
`--add-cloudsql-instances`, and sets `DB_HOST=/cloudsql/<conn>`, `DB_NAME`,
`DB_USER`, plus the `DB_PASSWORD` secret.

## 5. Set the frontend Firebase config as GitHub repo variables

These are public (shipped in the bundle); the deploy workflow injects them.

```bash
R=samechikson/putting-gate-app
gh variable set VITE_FIREBASE_API_KEY             --repo $R --body "<apiKey>"
gh variable set VITE_FIREBASE_AUTH_DOMAIN         --repo $R --body "putting-gate.firebaseapp.com"
gh variable set VITE_FIREBASE_PROJECT_ID          --repo $R --body "putting-gate"
gh variable set VITE_FIREBASE_APP_ID              --repo $R --body "<appId>"
gh variable set VITE_FIREBASE_STORAGE_BUCKET      --repo $R --body "<storageBucket>"
gh variable set VITE_FIREBASE_MESSAGING_SENDER_ID --repo $R --body "<messagingSenderId>"
# Optional cleanup of the now-unused Supabase vars:
gh variable delete VITE_SUPABASE_URL --repo $R; gh variable delete VITE_SUPABASE_ANON_KEY --repo $R
```

Also fill the same values into `frontend/.env.local` for local dev.

## 6. Migrate the data

### 6a. Users → Firebase Auth (preserve UID, password reset)

Export users from Supabase (SQL editor or `psql` against the Supabase DB):

```sql
select id, email from auth.users where email is not null;
```

Build a Firebase import file that **preserves each UID** (so migrated rows stay
attached) with **no password** — users reset via email:

```json
{ "users": [ { "localId": "<supabase-uuid>", "email": "<email>", "emailVerified": true } ] }
```

```bash
firebase auth:import users.json --project putting-gate
# Send each migrated user a reset link (console → Authentication, or Admin SDK
# generatePasswordResetLink / sendPasswordResetEmail).
```

### 6b. Tables → Cloud SQL (Postgres → Postgres)

```bash
# Dump data only for our three tables from Supabase, in FK order.
pg_dump "$SUPABASE_DB_URL" --data-only --no-owner --no-privileges \
  -t public.putters -t public.sessions -t public.putts > data.sql

# Load into Cloud SQL (schema already applied in step 2). user_id UUID strings
# load into the new text column; putter_id/session_id FKs are preserved.
gcloud sql connect putting-gate-db --user=app --database=putting_gate < data.sql
```

Verify row-count parity:

```sql
select 'putters' t, count(*) from putters
union all select 'sessions', count(*) from sessions
union all select 'putts', count(*) from putts;
```

## 7. iOS: add the Firebase SDK

In Xcode (code changes are already in the branch):
1. **File → Add Package Dependencies →** `https://github.com/firebase/firebase-ios-sdk`
   → add **FirebaseAuth** (pulls FirebaseCore) to the app target.
2. Drag `GoogleService-Info.plist` (step 3) into the app target (Copy if needed).
3. Build & run; confirm sign-in, upload, and that the session appears on web
   under the same account.

## 8. Cutover

1. Deploy the backend: `bash backend/deploy/cloud-run.sh` (provisions IAM +
   Cloud SQL wiring, builds, deploys, sets `PROCESS_URL=.../api/process`).
2. Merge `migrate-supabase-to-firebase` → `main`. CI builds the frontend with the
   Firebase repo vars and deploys to Hosting.
3. **Verify** (see checklist below).
4. Decommission Supabase: revoke keys, pause/delete the project.

## 9. Verification checklist

- `curl https://putting-gate.web.app/api/health` → `{"status":"ok"}`.
- Unauthenticated `curl …/api/sessions` → **401**.
- Web: sign up a new user → sign out → sign in. Migrated user resets password and
  sees their historical sessions/putters.
- Ownership: a user cannot read another user's sessions/putters.
- Upload a clip → status polls `queued → processing → done`; video plays back.
- Putters: add/edit/delete; activating one leaves exactly one active.
- iOS: sign in, upload, session shows on web under the same account (UID preserved).

## Rollback

Until Supabase is decommissioned (step 8.4), rollback is: revert the `main` merge
(CI redeploys the old frontend) and redeploy the previous backend revision
(`gcloud run services update-traffic putting-gate-backend --to-revisions=<prev>=100`).
Data written to Cloud SQL after cutover would need manual reconciliation, so keep
the cutover window short.
