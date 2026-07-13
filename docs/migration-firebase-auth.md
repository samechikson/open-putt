# Migration runbook: Supabase Auth → Firebase Auth (data stays on Supabase)

Operator runbook for moving **authentication** to Firebase while keeping the
**database on Supabase Postgres**, and routing all data access through the
backend (the browser and iOS no longer hit Supabase directly).

The application code is already migrated on branch `migrate-supabase-to-firebase`.
The backend now connects straight to Supabase's Postgres with `psycopg` (via the
connection pooler) as the service role, verifies Firebase ID tokens, and enforces
ownership per-user. The steps below are the infra + data work in your
GCP/Firebase/Supabase accounts, ending in an atomic cutover.

> ⚠️ **Do not merge the branch to `main` until steps 1–5 are done and the
> `VITE_FIREBASE_*` repo variables are set.** CI auto-deploys the frontend on
> push, and it needs the Firebase config + a Firebase-auth backend, or the live
> site breaks.

Project: `putting-gate` (Firebase + Cloud Run). Region `us-central1`.

**No Cloud SQL, no data-table migration** — the sessions/putts/putters rows stay
in Supabase. Only the schema is nudged (migration 0004) and users are recreated
in Firebase.

---

## 1. Enable Firebase Auth + register apps

In the [Firebase console](https://console.firebase.google.com/project/putting-gate):
1. **Authentication → Sign-in method → Email/Password → Enable.**
2. **Project settings → Your apps → Add app → Web.** Copy the config values
   (`apiKey`, `authDomain`, `projectId`, `appId`, `storageBucket`,
   `messagingSenderId`).
3. **Add app → iOS**, bundle id matching the Xcode target. Download
   `GoogleService-Info.plist`.

## 2. Migrate the Supabase schema (0004)

Apply `supabase/migrations/0004_firebase_auth.sql` — it drops the client RLS
policies + the `set_active_putter` function, drops the `auth.users` FKs, and
widens `user_id` from `uuid` to `text` (Firebase UIDs). Existing UUID values cast
cleanly and stay valid.

Run it via the Supabase SQL editor, or `supabase db push`, or:
```bash
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/0004_firebase_auth.sql
```

## 3. Point the backend at Supabase Postgres (DATABASE_URL)

In the Supabase dashboard: **Project settings → Database → Connection pooling** →
copy the pooler connection string. Use the **Transaction** pooler (IPv4, works
from Cloud Run) and append `?sslmode=require`:

```
DATABASE_URL=postgresql://postgres.<ref>:<db-password>@aws-0-<region>.pooler.supabase.com:6543/postgres?sslmode=require
```

Put it in `backend/.env` (read by the deploy script), replacing the old
`SUPABASE_*` entries. The code already disables prepared statements
(`prepare_threshold=None`) for pooler compatibility. `cloud-run.sh` seeds this as
the `DATABASE_URL` secret and sets `FIREBASE_PROJECT_ID` for token verification.

## 4. Set the frontend Firebase config as GitHub repo variables

Public values (shipped in the bundle); the deploy workflow injects them.

```bash
R=samechikson/putting-gate-app
gh variable set VITE_FIREBASE_API_KEY             --repo $R --body "<apiKey>"
gh variable set VITE_FIREBASE_AUTH_DOMAIN         --repo $R --body "putting-gate.firebaseapp.com"
gh variable set VITE_FIREBASE_PROJECT_ID          --repo $R --body "putting-gate"
gh variable set VITE_FIREBASE_APP_ID              --repo $R --body "<appId>"
gh variable set VITE_FIREBASE_STORAGE_BUCKET      --repo $R --body "<storageBucket>"
gh variable set VITE_FIREBASE_MESSAGING_SENDER_ID --repo $R --body "<messagingSenderId>"
# Optional: remove the now-unused Supabase vars.
gh variable delete VITE_SUPABASE_URL --repo $R; gh variable delete VITE_SUPABASE_ANON_KEY --repo $R
```

Also fill the same values into `frontend/.env.local` for local dev.

## 5. Migrate users → Firebase (preserve UID, password reset)

Export users from Supabase (SQL editor):
```sql
select id, email from auth.users where email is not null;
```

Import into Firebase **preserving each UID** (so existing `user_id` values still
match) with **no password** — users reset via email:
```json
{ "users": [ { "localId": "<supabase-uuid>", "email": "<email>", "emailVerified": true } ] }
```
```bash
firebase auth:import users.json --project putting-gate
# Then send each user a reset link (console → Authentication, or Admin SDK
# generatePasswordResetLink / sendPasswordResetEmail).
```

## 6. iOS: add the Firebase SDK

In Xcode (Swift changes already in the branch):
1. **File → Add Package Dependencies →** `https://github.com/firebase/firebase-ios-sdk`
   → add **FirebaseAuth** to the app target.
2. Add `GoogleService-Info.plist` (step 1) to the app target.
3. Build & run; confirm sign-in, upload, and that the session appears on web.

## 7. Cutover

1. Deploy the backend: `bash backend/deploy/cloud-run.sh` (seeds the DATABASE_URL
   secret, sets FIREBASE_PROJECT_ID, builds, deploys, sets
   `PROCESS_URL=.../api/process`).
2. Merge `migrate-supabase-to-firebase` → `main`. CI builds the frontend with the
   Firebase repo vars and deploys to Hosting.
3. **Verify** (checklist below).
4. In Supabase, you can now disable the Auth provider / stop relying on the anon
   key (the app no longer uses either). The Postgres database stays.

## 8. Verification checklist

- `curl https://putting-gate.web.app/api/health` → `{"status":"ok"}`.
- Unauthenticated `curl …/api/sessions` → **401**.
- Web: sign up a new user → sign out → sign in. A migrated user resets password
  and sees their historical sessions/putters.
- Ownership: a user cannot read another user's sessions/putters.
- Upload a clip → status polls `queued → processing → done`; video plays back.
- Putters: add/edit/delete; activating one leaves exactly one active.
- iOS: sign in, upload, session shows on web under the same account.

## Rollback

Until you disable Supabase Auth (step 7.4), rollback is: revert the `main` merge
(CI redeploys the old frontend) and redeploy the previous backend revision
(`gcloud run services update-traffic putting-gate-backend --to-revisions=<prev>=100`).
Keep the cutover window short so little new data is written under the new UIDs.
