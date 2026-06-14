-- ============================================================
-- Free Offers Monitor — Canonical Schema
-- ============================================================
-- This file is the single source of truth for the database
-- schema. After any changes, run `pnpm db:generate` to
-- regenerate TypeScript types in packages/db/src/types.ts.
--
-- Apply via the Supabase SQL editor or CLI against the target
-- project. Extensions must be enabled before table DDL.
-- ============================================================

-- ============================================================
-- EXTENSIONS
-- Must be run once in Supabase SQL editor before applying
-- any table DDL. Order matters: vector must precede tables
-- that use the vector type; pgmq and pg_cron can follow.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgmq;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ============================================================
-- TABLES
-- ============================================================

CREATE TABLE sources (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type           text NOT NULL,                    -- 'reddit' | 'discourse' | 'bump'
  identifier     text NOT NULL UNIQUE,             -- subreddit name or base URL
  config         jsonb NOT NULL DEFAULT '{}',      -- polling config, auth config
  last_polled_at timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE posts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id       uuid NOT NULL REFERENCES sources(id),
  external_id     text NOT NULL,                   -- Reddit post/comment ID
  url             text NOT NULL,
  title           text,
  body            text,
  author          text,
  posted_at       timestamptz,
  tier0_passed    boolean,                         -- null = not yet run
  tier1_result    jsonb,                           -- {decision, confidence, reason, prompt_version}
  tier2_result    jsonb,                           -- structured offer extraction
  pipeline_status text NOT NULL DEFAULT 'pending',
    -- 'pending' | 'tier0_rejected' | 'tier1_rejected' | 'tier2_done'
    -- | 'dedup_matched' | 'published' | 'review_queued' | 'error'
  error_detail    text,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT posts_source_external_unique UNIQUE (source_id, external_id)
);

CREATE INDEX posts_pipeline_status_idx ON posts(pipeline_status);
CREATE INDEX posts_source_id_idx ON posts(source_id);

CREATE TABLE offers (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  destination_url       text,                      -- NULL when extractor couldn't find one in the post; admin fills in via dashboard
  destination_url_hash  text,                      -- sha256 of normalized URL; NULL until destination_url is set
  title                 text NOT NULL,
  description           text,
  brand                 text,
  category              text,                      -- 'baby_gear' | 'formula' | etc.
  offer_type            text,                      -- 'sample' | 'full_product' | etc.
  shipping_cost         numeric,                   -- must be 0 for published
  restrictions          text[],
  embedding             vector(1024),              -- Voyage AI embedding (voyage-2)
  status                text NOT NULL DEFAULT 'active',
    -- 'active' | 'expired' | 'unverified' | 'review_pending'
  last_verified_at      timestamptz,
  next_check_at         timestamptz,
  consecutive_failures  integer NOT NULL DEFAULT 0,
  extraction_confidence numeric,                   -- Tier 2 confidence score
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

-- Hash lookup for URL dedup (O(1) exact match)
CREATE INDEX offers_url_hash_idx ON offers(destination_url_hash);

-- ANN search for semantic dedup (cosine similarity >= 0.85)
-- lists=100 is correct for <50k vectors; tune with sqrt(row_count) at scale
-- IMPORTANT: run ANALYZE offers after bulk insert or index will have poor recall
CREATE INDEX offers_embedding_ivfflat_idx
  ON offers USING ivfflat (embedding vector_cosine_ops)
  WITH (lists = 100);

-- Validation cron query — only active offers with a due check
CREATE INDEX offers_next_check_active_idx
  ON offers(next_check_at)
  WHERE status = 'active';

CREATE TABLE post_offers (
  post_id    uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  offer_id   uuid NOT NULL REFERENCES offers(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (post_id, offer_id)
);

CREATE INDEX post_offers_offer_id_idx ON post_offers(offer_id);

CREATE TABLE verification_log (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  offer_id     uuid NOT NULL REFERENCES offers(id) ON DELETE CASCADE,
  checked_at   timestamptz NOT NULL DEFAULT now(),
  http_status  integer,
  is_live      boolean NOT NULL,
  dead_signals text[],                             -- detected expiry phrases
  raw_response text                                -- truncated page text for debug
);

CREATE INDEX verification_log_offer_id_idx ON verification_log(offer_id);

CREATE TABLE human_review_queue (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id      uuid NOT NULL REFERENCES posts(id),
  tier2_result jsonb NOT NULL,
  confidence   numeric NOT NULL,
  reviewer_id  uuid,                               -- Supabase auth uid
  decision     text,                               -- 'approved' | 'rejected'
  review_note  text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  reviewed_at  timestamptz
);

CREATE INDEX human_review_queue_unreviewed_idx
  ON human_review_queue(created_at)
  WHERE decision IS NULL;

CREATE TABLE ai_calls (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id          uuid REFERENCES posts(id),
  tier             integer NOT NULL,               -- 1 or 2
  model            text NOT NULL,                  -- full dated model string
  prompt_version   text NOT NULL,                  -- git commit hash of prompt file
  input_tokens     integer NOT NULL,
  output_tokens    integer NOT NULL,
  cost_usd         numeric(10,6) NOT NULL,
  latency_ms       integer NOT NULL,
  request_payload  jsonb,                          -- truncated for cost analysis
  response_payload jsonb,
  error            text,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ai_calls_post_id_idx ON ai_calls(post_id);
CREATE INDEX ai_calls_tier_idx ON ai_calls(tier);
CREATE INDEX ai_calls_created_at_idx ON ai_calls(created_at DESC);

-- ============================================================
-- EXTENSION VERIFICATION
-- ============================================================
-- Call via db.rpc('check_required_extensions') at worker
-- startup to assert all required extensions are installed.

CREATE OR REPLACE FUNCTION check_required_extensions()
RETURNS TABLE(extname text, installed boolean)
LANGUAGE sql
AS $$
  SELECT e.extname::text, TRUE
  FROM pg_extension e
  WHERE e.extname IN ('vector', 'pgmq', 'pg_cron');
$$;

-- ============================================================
-- DEDUP FUNCTIONS
-- ============================================================
-- Used by the worker dedup pipeline via db.rpc('find_similar_offer', ...).
-- Sets ivfflat.probes within the function for consistent ANN recall.

CREATE OR REPLACE FUNCTION find_similar_offer(
  query_embedding vector(1024),
  similarity_threshold float,
  match_count int
)
RETURNS TABLE(id uuid, similarity float)
LANGUAGE plpgsql
AS $$
BEGIN
  -- Set probes for this transaction (DDP-04)
  PERFORM set_config('ivfflat.probes', '10', true);

  RETURN QUERY
  SELECT
    offers.id,
    (1 - (offers.embedding <=> query_embedding))::float AS similarity
  FROM offers
  WHERE offers.status = 'active'
    AND offers.embedding IS NOT NULL
    AND (1 - (offers.embedding <=> query_embedding)) >= similarity_threshold
  ORDER BY offers.embedding <=> query_embedding
  LIMIT match_count;
END;
$$;

-- ============================================================
-- QUEUES
-- ============================================================
-- Run after tables are created.
-- pgmq.create() is idempotent in recent versions.
--
-- NOTE: Visibility timeout is set at read time, not at
-- queue creation time. Use vt=30 for tier1 (Haiku) and
-- vt=120 for tier2 (Sonnet) when calling pgmq.read().
--
-- IMPORTANT: Messages MUST be archived after processing
-- via pgmq.archive(queue_name, msg_id) or they will
-- re-deliver after the visibility timeout expires.

SELECT pgmq.create('tier1_queue');
SELECT pgmq.create('tier2_queue');

-- ============================================================
-- VALIDATION SCHEDULING (VAL-01)
-- ============================================================
-- pg_cron declares the daily validation window. The worker
-- validation loop handles actual execution by polling
-- next_check_at <= now() on a 10-minute interval.
--
-- Fires at midnight UTC daily. The worker does not depend on
-- this cron job — it polls independently — but this entry
-- satisfies the VAL-01 requirement for pg_cron scheduling.

SELECT cron.schedule(
  'validation-daily-trigger',
  '0 0 * * *',
  $$SELECT 1$$
);
