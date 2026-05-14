-- Build 6 — wear-count RPC.
--
-- Phase 5 added VersatilityScorer's frequency component back into
-- the score, but the docstring's promise that `wear_count` would
-- track real wear behaviour was never wired through. This migration
-- adds a `security definer` function that the iOS client calls when
-- the user marks an outfit as worn: it bumps every item in that
-- outfit's `wear_count` and refreshes `last_worn_at` to `now()`.
--
-- The function filters by `auth.uid()` so users can only ever bump
-- their own items; RLS still protects against cross-user writes
-- because the `wardrobe_items` table's policies require ownership.
-- The `security definer` modifier lets us encapsulate the multi-id
-- update behind a single round trip and run it atomically.
--
-- Companion repository method:
--   `OutfitRepository.incrementWearCounts(itemIds:)`

create or replace function wardrobe_items_increment_wear_count(item_ids uuid[])
returns void
language sql
security definer
set search_path = public
as $$
  update wardrobe_items
  set wear_count = wear_count + 1,
      last_worn_at = now()
  where id = any(item_ids)
    and user_id = auth.uid();
$$;

grant execute on function wardrobe_items_increment_wear_count(uuid[]) to authenticated;

-- Note: the iOS client only invokes this function when the user
-- *adds* a worn-flag (isWorn = true). Toggling worn → not-worn
-- intentionally does NOT decrement; we treat wear as monotonically
-- increasing because the user observably wore the outfit once.
