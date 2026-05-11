-- Build 6 — persist the user's preferred default vibe.
--
-- Phase 6 shipped the slider as ephemeral per-generation state. This
-- migration adds the column that lets a user set "I want my default
-- to be Adventurous" in Settings and have every generation start
-- there going forward (with per-generation override still available
-- on the slider).
--
-- The default value is `'balanced'` so existing rows hydrate
-- correctly. The CHECK constraint mirrors `VibeStop.rawValue` exactly
-- so a stale client can never write garbage.

alter table profiles
    add column if not exists default_vibe text
    not null default 'balanced'
    check (default_vibe in ('safe', 'polished', 'balanced', 'adventurous', 'bold'));

comment on column profiles.default_vibe is
    'Default outfit-generation vibe (Safe / Polished / Balanced / Adventurous / Bold). See VibeStop.swift in the iOS client.';
