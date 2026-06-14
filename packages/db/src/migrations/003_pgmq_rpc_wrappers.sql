-- 003_pgmq_rpc_wrappers.sql
--
-- pgmq RPC wrapper functions. These live in the `public` schema so the
-- Supabase/PostgREST client can reach them via `db.rpc(...)`; the underlying
-- pgmq.* functions live in the `pgmq` schema and are NOT exposed over PostgREST.
-- The worker crashes on boot without these (see MIGRATION.md §0.2 / §2.3 / §11).
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ VERIFY BEFORE APPLYING (MIGRATION.md §0.2)                                │
-- │ The definitions below are the standard pgmq wrapper shape and match the   │
-- │ signatures the worker actually calls. Capture the REAL definitions from   │
-- │ the old DB and replace the bodies below if they differ:                   │
-- │                                                                           │
-- │   SELECT pg_get_functiondef(p.oid)                                        │
-- │   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace            │
-- │   WHERE n.nspname = 'public'                                              │
-- │     AND p.proname IN ('pgmq_send','pgmq_read','pgmq_archive',             │
-- │                       'pgmq_create');                                     │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- Call sites (do not change these signatures without updating the worker):
--   apps/worker/src/queue/producer.ts   pgmq_send(queue_name, msg)
--   apps/worker/src/queue/consumer.ts   pgmq_read(queue_name, vt, qty), pgmq_archive(queue_name, msg_id)
--   apps/worker/src/index.ts            pgmq_create(queue_name)

-- pgmq_create(queue_name text) — idempotent in recent pgmq; worker tolerates "already exists".
CREATE OR REPLACE FUNCTION public.pgmq_create(queue_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pgmq
AS $$
BEGIN
  PERFORM pgmq.create(queue_name);
END;
$$;

-- pgmq_send(queue_name text, msg jsonb) -> msg_id bigint
CREATE OR REPLACE FUNCTION public.pgmq_send(queue_name text, msg jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pgmq
AS $$
DECLARE
  msg_id bigint;
BEGIN
  SELECT * INTO msg_id FROM pgmq.send(queue_name, msg);
  RETURN msg_id;
END;
$$;

-- pgmq_read(queue_name text, vt int, qty int) -> setof message rows
-- Returns SETOF pgmq.message_record so the output columns come from pgmq's own
-- composite type (msg_id, read_ct, enqueued_at, vt, message) rather than being
-- declared here. Declaring an output column named `vt` would collide with the
-- input parameter `vt` (PL/pgSQL error 42P13). The shape still matches
-- PgmqMessage in apps/worker/src/queue/consumer.ts: { msg_id, read_ct,
-- enqueued_at, vt, message }.
CREATE OR REPLACE FUNCTION public.pgmq_read(queue_name text, vt integer, qty integer)
RETURNS SETOF pgmq.message_record
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pgmq
AS $$
BEGIN
  RETURN QUERY SELECT * FROM pgmq.read(queue_name, vt, qty);
END;
$$;

-- pgmq_archive(queue_name text, msg_id bigint) -> boolean
CREATE OR REPLACE FUNCTION public.pgmq_archive(queue_name text, msg_id bigint)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pgmq
AS $$
DECLARE
  archived boolean;
BEGIN
  SELECT pgmq.archive(queue_name, msg_id) INTO archived;
  RETURN archived;
END;
$$;
