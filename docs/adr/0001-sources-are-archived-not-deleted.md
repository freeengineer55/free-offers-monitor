# Sources are archived, never hard-deleted

A **Source** carries a `status` of `active | paused | archived`. "Removing" a Source from the dashboard sets `status='archived'` (hidden from the default view, never polled); no `sources` row is ever `DELETE`d.

We chose this because `posts.source_id` is a foreign key and Posts are the provenance of every extracted **Offer** (via `post_offers`) and of the embedding/URL-hash dedup history. A hard delete would either be blocked by the FK or, with cascade, destroy Offer lineage and force the dedup index to re-learn. The cost is that the `sources` table accumulates archived rows forever — an acceptable trade for never losing history. `fetchActiveSources()` filters on `status='active'`, so archived/paused Sources are simply skipped each cycle.
