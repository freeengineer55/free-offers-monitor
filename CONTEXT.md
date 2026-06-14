# Free Offers Monitor

The domain language for an automated pipeline that scans online communities and blogs for genuinely free physical goods aimed at new mothers and families with babies, then publishes verified offers to an admin dashboard.

## Language

**Source**:
A single place the pipeline polls for new content — e.g. one subreddit or one forum URL. Stored as a row in `sources` with a **Source Type**, an identifier, and config. An admin can add, pause, or remove Sources from the dashboard. A Source is always in one of three **Source Statuses**.
_Avoid_: Site, website, blog, feed (these are informal names for a Source).

**Source Status**:
The lifecycle state of a Source. **Active** — polled every cycle. **Paused** — temporarily not polled, still visible in the dashboard. **Archived** — permanently retired: never polled, hidden from the default dashboard view, but its row and all its Posts/Offers are kept. "Removing" a Source means archiving it; Sources are never hard-deleted, so Offer lineage and dedup history survive.

**Source Type**:
A supported *format* of Source, each backed by a dedicated **Adapter** that knows how to read that format (currently `reddit` and `bump`). Adding a brand-new Source Type requires a developer to write an Adapter — admins cannot create Source Types from the dashboard, only new Sources of an existing type.
_Avoid_: Platform, provider.

**Adapter**:
The code that knows how to fetch posts from one Source Type and return them in a normalized shape. One Adapter serves all Sources of its Type.

**Post**:
A single item fetched from a Source (a Reddit submission/comment, a forum thread) before classification.

**Offer**:
A genuinely free physical-goods offering extracted from one or more Posts: zero shipping cost, no coupons, no services, no trials, no sweepstakes. The published unit of value.

## Flagged ambiguities

- "Add a new website/blog" from a stakeholder means **add a new Source of an existing Source Type**, NOT teach the system a new format. Novel formats are a developer task.
- The `sources.type` column comment in `schema.sql` says `'reddit' | 'discourse'`, but the worker actually dispatches on `'reddit'` and `'bump'`. The schema comment is stale; `bump` is the real second Source Type.
