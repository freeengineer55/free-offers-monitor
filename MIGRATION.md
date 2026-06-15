# Migration & Handoff Runbook

Move Free Offers Monitor from its current home (a Supabase project with real data; worker + dashboard run **locally**) to a fresh set of accounts you provision, then hand the running system over to a new owner.

This is a **data migration + first-time deploy + ownership handoff**, not a redeploy. Read it once end to end before starting.

## Decisions this runbook assumes

These were settled during planning — see `CONTEXT.md` and `docs/adr/`:

- **Full data migration** — every business table moves (offers, embeddings, posts, sources, ai_calls, …), not just a curated subset.
- **You provision all** new accounts, migrate, deploy, verify green, **then transfer logins**. AI/data keys (Anthropic, Voyage, Axiom, Reddit User-Agent) stay on your billing through cutover; the new owner reissues them afterward (see §10).
- **No feature work** — the Sources-management dashboard feature is documented design only (`docs/adr/0001`, `0002`). Do **not** apply the `sources.status` change. Migrate the schema as it exists today.
- **Old Supabase is the rollback** — it is not torn down until the new owner confirms the system is healthy.

## Topology

| Piece | Old (today) | New (after migration) |
|-------|-------------|------------------------|
| Database | Supabase project (real data) | New Supabase project |
| Worker | runs locally (`pnpm dev --filter worker`) | Railway service (first deploy) |
| Dashboard | runs locally (`pnpm dev --filter dashboard`) | Vercel project (first deploy) |
| Repo | local + old GitHub | new GitHub repo |
| AI/data keys | yours | yours through cutover, then rotated to new owner |

---

## 0. Pre-flight inventory (do this first, while the old system is intact)

Capture everything the repo does **not** already contain. `schema.sql` is incomplete (it omits the `pgmq_*` RPC wrappers the worker depends on), so do not assume you can rebuild the DB from the repo alone.

From the **old** Supabase (SQL editor or `psql "$OLD_DB_URL"`):

1. **Row counts** — record a baseline to verify against after restore:
   ```sql
   SELECT 'sources' t, count(*) FROM sources
   UNION ALL SELECT 'posts', count(*) FROM posts
   UNION ALL SELECT 'offers', count(*) FROM offers
   UNION ALL SELECT 'post_offers', count(*) FROM post_offers
   UNION ALL SELECT 'verification_log', count(*) FROM verification_log
   UNION ALL SELECT 'human_review_queue', count(*) FROM human_review_queue
   UNION ALL SELECT 'ai_calls', count(*) FROM ai_calls;
   ```
2. **The pgmq RPC wrapper functions** (NOT in `schema.sql` — critical):
   ```sql
   SELECT pg_get_functiondef(p.oid)
   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('pgmq_send','pgmq_read','pgmq_archive','pgmq_create');
   ```
   Save the output to `packages/db/src/migrations/003_pgmq_rpc_wrappers.sql`. (Committing this back fixes the repo gap for the new owner — see §11.)
3. **Any other custom `public` functions** beyond `check_required_extensions` and `find_similar_offer` (already in `schema.sql`):
   ```sql
   SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prokind='f';
   ```
4. **pg_cron jobs** currently scheduled:
   ```sql
   SELECT jobname, schedule, command FROM cron.job;
   ```
5. **Allowlisted dashboard users** (these live in `auth.users`, do NOT travel with a business-table dump — the new owner re-invites them):
   ```sql
   SELECT email FROM auth.users ORDER BY created_at;
   ```
6. **The current `.env.local`** values (your working AI/data keys). You'll paste these into Railway/Vercel.

---

## 1. Provision the new accounts

Create in this order; later steps consume earlier values. Use a fresh email as the recovery address on all of them.

1. **Email** — the new owner's (or a neutral) inbox; it's the recovery anchor for everything below.
2. **GitHub** — new account. Create an **empty** repo (no README). Then push existing history:
   ```bash
   git remote add neworigin git@github.com:<new-acct>/free-offers-monitor.git
   git push neworigin --all
   git push neworigin --tags
   ```
   Archive (don't delete) the old repo once Vercel/Railway point at the new one.
3. **Supabase** — new project. Pick a region close to your Railway region. Save the DB password.
4. **Railway** — new account (deploy in §8).
5. **Vercel** — new account (deploy in §8).

Anthropic / Voyage / Axiom / Reddit: **reuse your existing accounts** for now. The new owner rotates them post-handoff (§10).

---

## 2. Prepare the new Supabase database (schema BEFORE data)

In the new project's SQL editor, in order:

1. **Enable extensions** (Database → Extensions: toggle `vector`, `pgmq`, `pg_cron` on first), then:
   ```sql
   CREATE EXTENSION IF NOT EXISTS vector;
   CREATE EXTENSION IF NOT EXISTS pgmq;
   CREATE EXTENSION IF NOT EXISTS pg_cron;
   ```
2. **Apply `packages/db/src/schema.sql`** — creates tables, indexes, `check_required_extensions`, `find_similar_offer`, the `tier1_queue` / `tier2_queue` queues, and the `validation-daily-trigger` cron job.
3. **Apply migrations in order:**
   - `migrations/002_destination_url_nullable.sql` (makes `offers.destination_url[_hash]` nullable — required, the data depends on it).
   - `migrations/003_pgmq_rpc_wrappers.sql` (the wrappers you captured in §0.2 — **the worker will crash on boot without these**).
   - Do **NOT** apply `001_seed_thebump_sources.sql` — those source rows arrive via the data restore. Re-seeding would duplicate-collide on `identifier`.
4. **Verify the queues exist:**
   ```sql
   SELECT queue_name FROM pgmq.list_queues();  -- expect tier1_queue, tier2_queue
   ```
   (`tier1_dlq` / `tier2_dlq` auto-create when the worker first boots — no action needed.)

Leave the business tables **empty** for now; data lands in §6.

---

## 3. Quiesce the old system

The pipeline is live in your local worker. Stop it cleanly so no message is mid-flight when you dump.

1. **Stop the local worker** (Ctrl-C the `pnpm dev --filter worker` process). Ingestion, both tier consumers, and validation all halt.
2. **Confirm the queues are drained** on the old DB:
   ```sql
   SELECT queue_name, queue_length FROM pgmq.metrics_all()
   WHERE queue_name IN ('tier1_queue','tier2_queue');
   ```
   Both lengths should reach `0`. If not, briefly restart the worker to let consumers finish, then stop again. (In-flight queue messages are intentionally **not** migrated — they'd reference posts that already carry their result in `posts.tier1_result` / `tier2_result`.)
3. From here until cutover completes, **do not restart the old worker** — the old DB must stay frozen so it's a valid rollback point.

---

## 4. Dump the old data

Use a **data-only** dump of the business tables, in FK-safe order. Schema and functions are already in place on the new side from §2, so we move data only — this keeps the repo as the schema source of truth and avoids copying pgmq/cron internal state.

```bash
OLD_DB_URL='postgresql://postgres:<pwd>@db.<old-ref>.supabase.co:5432/postgres'

pg_dump "$OLD_DB_URL" \
  --data-only --no-owner --no-privileges \
  --table=public.sources \
  --table=public.posts \
  --table=public.offers \
  --table=public.post_offers \
  --table=public.verification_log \
  --table=public.human_review_queue \
  --table=public.ai_calls \
  --file=fom-data.sql
```

Notes:
- The `offers.embedding` `vector(1024)` column dumps as a text literal and restores fine **because the `vector` extension already exists** on the new DB (§2.1). Don't skip that.
- `--table` flags load in the order listed, which already respects the FK chain (sources → posts → offers → join/log/queue/ai_calls).

---

## 5. Restore into the new Supabase

```bash
NEW_DB_URL='postgresql://postgres:<pwd>@db.<new-ref>.supabase.co:5432/postgres'

psql "$NEW_DB_URL" -v ON_ERROR_STOP=1 -f fom-data.sql
```

If the restore errors on a FK violation, it almost always means table order — re-dump with the `--table` flags in the exact order in §4.

---

## 6. Post-restore: index quality + verification

The `ivfflat` embedding index was created empty in §2 (by `schema.sql`); its centroids are meaningless until the data is present. Fix recall and verify:

1. **Rebuild the embedding index + analyze** (the `schema.sql` comment calls this out explicitly):
   ```sql
   REINDEX INDEX offers_embedding_ivfflat_idx;
   ANALYZE offers;
   ```
2. **Verify row counts** match the §0.1 baseline exactly:
   ```sql
   SELECT 'sources' t, count(*) FROM sources
   UNION ALL SELECT 'posts', count(*) FROM posts
   UNION ALL SELECT 'offers', count(*) FROM offers
   UNION ALL SELECT 'ai_calls', count(*) FROM ai_calls;
   ```
3. **Spot-check dedup** still works (an existing offer should match itself ≥ 0.85):
   ```sql
   SELECT * FROM find_similar_offer(
     (SELECT embedding FROM offers WHERE embedding IS NOT NULL LIMIT 1),
     0.85, 5);
   ```
4. **Re-create dashboard auth users** — Authentication → Providers → Email: enable, **disable signups**. Then add each email captured in §0.5 via **Authentication → Users → Add user**, checking **"Auto Confirm User"** and setting a password.
   - The dashboard logs in with **email + password** (`signInWithPassword` in `apps/dashboard/components/auth/login-form.tsx`). It has **no magic-link / invite-callback route**, so the "Invite user" flow dead-ends (the link redirects to the Site URL with a recovery token the app can't handle). Use "Add user + Auto Confirm + password" and hand credentials to each user.
   - The allowlist is enforced a **second time** at the app layer via the `ALLOWED_EMAILS` env var (see §8) — adding the Supabase user is necessary but **not sufficient**; the email must also appear in `ALLOWED_EMAILS` or login is rejected with "Your account is not authorized."

---

## 7. Configure the new Supabase auth & cron (parity check)

- Confirm `validation-daily-trigger` exists (`SELECT * FROM cron.job;`). It came from `schema.sql` in §2. Expect exactly that one row.
- The old DB also had a `validate-offers-daily` cron that did `pgmq.send('validation_queue', …)` (§0.4). **Do not recreate it.** Nothing in the worker consumes `validation_queue` — `runValidationCycle` (`apps/worker/src/validation/validation-loop.ts`) queries the `offers` table directly for due offers. The cron + queue are orphaned dead state on the old DB (messages pile up unread); recreating them on the new DB would only reproduce that bug and trip the §9 "messages not piling up" check.
- The worker's 10-minute validation loop is the real validation path and runs regardless of cron, so dropping the orphaned cron loses nothing.

---

## 8. Deploy worker and dashboard (first-time)

### Worker → Railway
- New Project → Deploy from the GitHub repo.
- Build: `pnpm install --frozen-lockfile && pnpm build --filter worker`
- Start: `pnpm --filter worker start` (runs `node dist/index.js`; the `start` script was added during this migration). Prompt loading is now resolved relative to the worker module, not the cwd, so it works from either the repo root or `apps/worker`.
- Env vars:
  - `ANTHROPIC_API_KEY`, `VOYAGE_API_KEY` — your existing keys.
  - `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` — from the **new** project (Settings → API).
  - `REDDIT_USER_AGENT` — leave as-is for now (`/u/Alternative-Owl-7042`); the new owner changes it in §10.
  - `AXIOM_TOKEN`, `AXIOM_DATASET`, `AXIOM_ORG_ID` — all three together, optional (Axiom logging; console-only if unset). `PORT=3001`.
- Deploy. Tail logs for: `extensions_verified`, `prompts_loaded` (×2), `dlq_queue_created` (×2), `health_endpoint_listening`, `worker_started`, then the four loops. A missing `pgmq_*` wrapper shows up here as an RPC error — if so, revisit §2.3.

### Dashboard → Vercel
- Import the repo, root `apps/dashboard`, framework Next.js.
- Env (Production + Preview):
  - `NEXT_PUBLIC_SUPABASE_URL` = new project URL
  - `NEXT_PUBLIC_SUPABASE_ANON_KEY` = new anon key
  - `SUPABASE_URL` = new project URL — **required** in addition to the public one; `apps/dashboard/lib/actions/offers.ts` uses `@repo/db`'s service-role client, which reads the non-prefixed `SUPABASE_URL`.
  - `SUPABASE_SERVICE_ROLE_KEY` = new service role key
  - `ALLOWED_EMAILS` = comma-separated allowlist (the same emails added in §6.4, e.g. `a@x.com,b@y.com`). **Required** — `apps/dashboard/lib/actions/auth.ts` checks every authenticated user against this list and signs them out if absent. Without it, all logins are rejected.
- In Supabase, set **Auth → URL Configuration → Site URL** to the Vercel domain (so password-reset emails redirect correctly).
- Deploy. Log in with a §6.4 email + password; confirm `/dashboard/offers`, `/dashboard/review`, `/dashboard/ai-logs` render against migrated data.

---

## 9. Verify green (do not hand off until all pass)

- [ ] Worker logs show all four loops started, no RPC/extension errors.
- [ ] `curl https://<railway-domain>/health` → `OK`.
- [ ] Dashboard `/dashboard/offers` shows the migrated offers (count matches §0.1).
- [ ] Within ~5 min, `SELECT count(*) FROM posts;` on the new DB **grows** beyond the migrated baseline (ingestion is running and `last_polled_at` advanced).
- [ ] `SELECT count(*) FROM ai_calls WHERE created_at > now() - interval '10 min';` is non-zero (new Tier 1/2 calls firing).
- [ ] `pgmq.metrics_all()` shows messages flowing through and draining (not piling up).
- [ ] No duplicate offers created from the first ingestion cycle (dedup using the migrated embeddings — the REINDEX in §6.1 matters here).

Let the new stack run a full day and re-check before handoff so a validation cycle has fired.

---

## 10. Handoff: transfer ownership + rotate keys

Once §9 is green and stable:

1. **Transfer logins** — change the recovery email / password on the new GitHub, Supabase, Vercel, Railway accounts to the new owner's, or hand over credentials directly.
2. **New owner reissues AI/data keys under their billing**, then updates env and redeploys:
   - Anthropic → new `ANTHROPIC_API_KEY` (Railway).
   - Voyage → new `VOYAGE_API_KEY` (Railway). *(Embeddings already stored migrate fine; new key only affects future embeddings — model must stay `voyage-3`, 1024-dim.)*
   - Axiom → new `AXIOM_TOKEN` (Railway), optional.
   - **Reddit** → new owner's Reddit account; update `REDDIT_USER_AGENT` to `free-offers-monitor/1.0 (by /u/<their-account>)`. This is their identity to Reddit moderators.
3. **You revoke your old keys** (Anthropic/Voyage/Axiom consoles) only **after** the new owner confirms the rotated keys work — not before.
4. Hand over `actionsNeeded.md` (provisioning reference), this file, `CONTEXT.md`, and `docs/adr/` so the new owner has the full picture.

---

## 11. Rollback

If the new stack misbehaves before handoff completes:

- The **old Supabase is untouched and frozen** (§3). Restart your local worker against the old `.env.local` to resume the original system immediately.
- The new Supabase can be wiped and re-restored from `fom-data.sql` without touching the old data.
- Keep the old Supabase project alive until the new owner signs off on a full healthy day (§9), then delete it.

---

## Known repo gaps to fix during this migration

Capturing these in the repo makes the system reproducible for the new owner instead of depending on hidden DB state:

- **`pgmq_*` RPC wrappers** (§0.2) are not in `schema.sql`. Commit them as `migrations/003_pgmq_rpc_wrappers.sql`.
- **`schema.sql` `sources.type` comment** says `'reddit' | 'discourse'` but the real second type is `bump`. Fix the comment.
- **`auth.users` allowlist** is environment state, not code — document the allowed emails in the handoff notes (not in git). Note the allowlist is enforced in **two** places that must agree: the Supabase user must exist (added via Add user + Auto Confirm + password, §6.4) **and** the email must be in the dashboard's `ALLOWED_EMAILS` env var (§8).
- **Dashboard onboarding is password-only.** Login uses `signInWithPassword` and there is no invite/magic-link callback route. Add users with a password directly; the "Invite user" button does not work end to end. (Implementing an `/auth/callback` route is deferred feature work, not part of this migration.)
- **Worker had no `start` script and resolved prompts via cwd.** Both fixed during this migration: `apps/worker` now has `start: node dist/index.js`, and prompt loading resolves relative to the module so it is cwd-independent.
