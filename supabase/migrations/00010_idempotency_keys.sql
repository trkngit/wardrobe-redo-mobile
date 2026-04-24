-- ============================================================
-- Migration 00010: client-generated idempotency keys
-- ============================================================
--
-- Context:
--   The iOS upload path (AddItemViewModel + OutfitRepository.saveOutfit)
--   now retries transient network failures via withRetry(). Without an
--   idempotency key, a retried insert can create a duplicate row when
--   the original request succeeded server-side but the response got
--   lost in a network partition. This migration adds a nullable
--   idempotency_key UUID to both write-hot tables, with a partial
--   unique index so the second write hits a 23505 conflict the client
--   can treat as "already inserted, move on".
--
--   Rationale for scoping (user_id, idempotency_key) rather than
--   idempotency_key alone: clients generate keys with UUIDv4 which is
--   astronomically unique, but scoping to the user honors the RLS
--   boundary (no cross-user conflicts even in the 1-in-2^122 collision
--   path) and keeps the unique index covered by the existing
--   (user_id) filter predicate we already use.
--
-- Changes:
--   - wardrobe_items: add idempotency_key UUID (nullable)
--   - outfits:        add idempotency_key UUID (nullable)
--   - Partial unique index per table on (user_id, idempotency_key)
--     WHERE idempotency_key IS NOT NULL so legacy rows (NULL key) are
--     not constrained and new rows deduplicate on retry.
--
-- Rollback:
--   Indexes and columns are additive; drop in reverse:
--     DROP INDEX IF EXISTS wardrobe_items_user_idemp_uq;
--     ALTER TABLE wardrobe_items DROP COLUMN IF EXISTS idempotency_key;
--     DROP INDEX IF EXISTS outfits_user_idemp_uq;
--     ALTER TABLE outfits DROP COLUMN IF EXISTS idempotency_key;
-- ============================================================

ALTER TABLE wardrobe_items
    ADD COLUMN IF NOT EXISTS idempotency_key UUID;

COMMENT ON COLUMN wardrobe_items.idempotency_key IS
    'Client-generated UUID echoed back on retry to prevent duplicate inserts when a network partition hides a successful response. NULL on legacy rows and on non-retried writes. Enforced via partial unique index wardrobe_items_user_idemp_uq.';

CREATE UNIQUE INDEX IF NOT EXISTS wardrobe_items_user_idemp_uq
    ON wardrobe_items (user_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;

ALTER TABLE outfits
    ADD COLUMN IF NOT EXISTS idempotency_key UUID;

COMMENT ON COLUMN outfits.idempotency_key IS
    'Client-generated UUID echoed back on retry to prevent duplicate outfits when the iOS save path retries a timed-out saveOutfit(). NULL on legacy rows. Enforced via partial unique index outfits_user_idemp_uq.';

CREATE UNIQUE INDEX IF NOT EXISTS outfits_user_idemp_uq
    ON outfits (user_id, idempotency_key)
    WHERE idempotency_key IS NOT NULL;
