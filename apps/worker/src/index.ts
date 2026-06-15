import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';
import Anthropic from '@anthropic-ai/sdk';
import { createClient } from '@repo/db';
import { logger } from './logger.js';
import { POLL_INTERVAL_MS, TIER1_VISIBILITY_TIMEOUT, TIER2_VISIBILITY_TIMEOUT, CONSUMER_BATCH_SIZE } from './config.js';
import { fetchActiveSources, runIngestionCycle } from './ingestion/ingest.js';
import { runConsumerLoop, sleep } from './queue/consumer.js';
import { processTier1 } from './tiers/tier1.js';
import { processTier2 } from './tiers/tier2.js';
import { runValidationLoop } from './validation/validation-loop.js';

type DbClient = ReturnType<typeof createClient>;

/**
 * Compute the git short hash for prompt versioning.
 * Prefers RAILWAY_GIT_COMMIT_SHA env var (available on Railway).
 * Falls back to git rev-parse --short HEAD.
 * Returns 'unknown' if both fail.
 */
function computePromptVersion(): string {
  const railwayHash = process.env.RAILWAY_GIT_COMMIT_SHA;
  if (railwayHash) {
    return railwayHash.slice(0, 7);
  }

  try {
    return execSync('git rev-parse --short HEAD', { stdio: ['pipe', 'pipe', 'pipe'] })
      .toString()
      .trim();
  } catch {
    logger.warn('prompt_version_unknown', {
      reason: 'RAILWAY_GIT_COMMIT_SHA not set and git rev-parse failed',
    });
    return 'unknown';
  }
}

/**
 * Assert that all required Postgres extensions are installed.
 * Throws if any required extension is missing.
 */
async function assertRequiredExtensions(db: DbClient): Promise<void> {
  const { data, error } = await db.rpc('check_required_extensions');

  if (error) {
    throw new Error(`Failed to check required extensions: ${error.message}`);
  }

  const installed = new Set(
    ((data ?? []) as Array<{ extname: string; installed: boolean }>)
      .filter((row) => row.installed)
      .map((row) => row.extname),
  );

  const required = ['vector', 'pgmq', 'pg_cron'];
  const missing = required.filter((ext) => !installed.has(ext));

  if (missing.length > 0) {
    throw new Error(`Required Postgres extensions not installed: ${missing.join(', ')}`);
  }

  logger.info('extensions_verified', { installed: Array.from(installed) });
}

/**
 * Create DLQ queues idempotently at worker startup.
 * Swallows "already exists" errors gracefully.
 */
async function createDlqQueues(db: DbClient): Promise<void> {
  for (const queueName of ['tier1_dlq', 'tier2_dlq']) {
    const { error } = await db.rpc('pgmq_create', { queue_name: queueName });

    if (error) {
      // pgmq_create is idempotent in recent versions — log but don't throw on "already exists"
      if (error.message.toLowerCase().includes('already exists')) {
        logger.info('dlq_queue_already_exists', { queue: queueName });
      } else {
        logger.warn('dlq_queue_create_warning', { queue: queueName, error: error.message });
      }
    } else {
      logger.info('dlq_queue_created', { queue: queueName });
    }
  }
}

/**
 * Ingestion polling loop — fetches sources and runs one ingestion cycle per interval.
 * Catches errors per cycle so a transient failure does not crash the process.
 */
async function runIngestionLoop(
  db: DbClient,
  shutdown: { stop: boolean },
): Promise<void> {
  while (!shutdown.stop) {
    const cycleStart = Date.now();

    try {
      const sources = await fetchActiveSources(db);
      await runIngestionCycle(db, sources);
    } catch (err) {
      logger.error('ingestion_loop_error', { error: String(err) });
    }

    const elapsed = Date.now() - cycleStart;
    const remaining = Math.max(0, POLL_INTERVAL_MS - elapsed);

    if (!shutdown.stop && remaining > 0) {
      await sleep(remaining);
    }
  }

  logger.info('ingestion_loop_stopped');
}

/**
 * Tier 1 consumer loop — wraps runConsumerLoop with processTier1 handler.
 */
async function runTier1ConsumerLoop(
  db: DbClient,
  anthropic: Anthropic,
  prompt: string,
  promptVersion: string,
  shutdown: { stop: boolean },
): Promise<void> {
  await runConsumerLoop({
    db,
    queueName: 'tier1_queue',
    dlqName: 'tier1_dlq',
    visibilityTimeout: TIER1_VISIBILITY_TIMEOUT,
    batchSize: CONSUMER_BATCH_SIZE,
    shutdown,
    processMessage: (dbClient: DbClient, postId: string) =>
      processTier1({ db: dbClient, anthropic, postId, prompt, promptVersion }),
  });
}

/**
 * Tier 2 consumer loop — wraps runConsumerLoop with processTier2 handler.
 */
async function runTier2ConsumerLoop(
  db: DbClient,
  anthropic: Anthropic,
  prompt: string,
  promptVersion: string,
  shutdown: { stop: boolean },
): Promise<void> {
  await runConsumerLoop({
    db,
    queueName: 'tier2_queue',
    dlqName: 'tier2_dlq',
    visibilityTimeout: TIER2_VISIBILITY_TIMEOUT,
    batchSize: CONSUMER_BATCH_SIZE,
    shutdown,
    processMessage: (dbClient: DbClient, postId: string) =>
      processTier2({ db: dbClient, anthropic, postId, prompt, promptVersion }),
  });
}

/**
 * Worker entry point. Performs startup assertions, loads prompts, starts
 * the HTTP health endpoint, and runs the ingestion loop and Tier 1
 * consumer concurrently.
 */
async function main(): Promise<void> {
  logger.info('worker_starting');

  // Compute prompt version
  const promptVersion = computePromptVersion();
  logger.info('prompt_version', { version: promptVersion });

  // Load prompts from disk at startup — cached in memory for the process lifetime.
  // Resolve relative to this module (apps/worker/{src,dist}/index.* -> repo-root
  // /prompts) so it works regardless of the process working directory — i.e. the
  // worker can be started from the repo root or from apps/worker without the
  // prompt files going missing. PROMPTS_DIR overrides for non-standard layouts.
  const moduleDir = path.dirname(fileURLToPath(import.meta.url));
  const promptsDir = process.env.PROMPTS_DIR ?? path.resolve(moduleDir, '../../../prompts');

  const tier1Prompt = readFileSync(path.join(promptsDir, 'tier1-classify.md'), 'utf-8');
  logger.info('prompts_loaded', { tier1_chars: tier1Prompt.length });

  const tier2Prompt = readFileSync(path.join(promptsDir, 'tier2-extract.md'), 'utf-8');
  logger.info('tier2_prompt_loaded', { tier2_chars: tier2Prompt.length });

  // Initialize clients
  const db = createClient();
  const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

  // Assert required Postgres extensions
  await assertRequiredExtensions(db);

  // Create DLQ queues idempotently
  await createDlqQueues(db);

  // HTTP health endpoint
  const port = parseInt(process.env.PORT ?? '3001', 10);
  const server = createServer((req, res) => {
    if (req.url === '/health') {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('OK');
    } else {
      res.writeHead(404);
      res.end();
    }
  });

  server.listen(port, () => {
    logger.info('health_endpoint_listening', { port });
  });

  // Graceful shutdown
  const shutdown = { stop: false };

  const handleShutdown = (signal: string): void => {
    logger.info('shutdown_signal_received', { signal });
    shutdown.stop = true;
    server.close(() => {
      logger.info('http_server_closed');
    });
  };

  process.on('SIGTERM', () => handleShutdown('SIGTERM'));
  process.on('SIGINT', () => handleShutdown('SIGINT'));

  logger.info('worker_started', { port, prompt_version: promptVersion });

  // Run ingestion polling loop, Tier 1 consumer, Tier 2 consumer, and validation loop concurrently
  await Promise.all([
    runIngestionLoop(db, shutdown),
    runTier1ConsumerLoop(db, anthropic, tier1Prompt, promptVersion, shutdown),
    runTier2ConsumerLoop(db, anthropic, tier2Prompt, promptVersion, shutdown),
    runValidationLoop(db, shutdown),
  ]);

  logger.info('worker_stopped');
}

main().catch((err: unknown) => {
  console.error('Worker fatal error:', err);
  process.exit(1);
});
