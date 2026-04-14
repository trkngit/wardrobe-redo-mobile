-- Wardrobe Re-Do: Initial Schema
-- All tables, indexes, RLS policies, triggers

-- ============================================================
-- PROFILES (extends auth.users)
-- ============================================================
CREATE TABLE profiles (
    id                    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    display_name          TEXT NOT NULL DEFAULT 'User',
    tier                  TEXT NOT NULL DEFAULT 'free' CHECK (tier IN ('free', 'premium')),
    style_preferences     JSONB DEFAULT '{}',
    onboarding_completed  BOOLEAN NOT NULL DEFAULT FALSE,
    timezone              TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view own profile" ON profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Users can insert own profile" ON profiles FOR INSERT WITH CHECK (auth.uid() = id);

-- Auto-create profile on signup
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO profiles (id, display_name)
    VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'display_name', 'User'));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER profiles_updated_at
    BEFORE UPDATE ON profiles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- WARDROBE ITEMS
-- ============================================================
CREATE TABLE wardrobe_items (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id               UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    image_path            TEXT NOT NULL,
    thumbnail_path        TEXT NOT NULL,
    category              TEXT NOT NULL CHECK (category IN ('top', 'bottom', 'shoe', 'dress', 'outerwear', 'accessory')),
    subcategory           TEXT NOT NULL,
    dominant_colors       JSONB NOT NULL DEFAULT '[]',
    texture               TEXT,
    fit_attribute         TEXT CHECK (fit_attribute IN ('oversized', 'relaxed', 'regular', 'slim', 'structured', 'cropped')),
    formality_components  JSONB,
    formality_computed    NUMERIC(3,1),
    seasons               TEXT[] NOT NULL DEFAULT '{spring,summer,fall,winter}',
    occasions             TEXT[] NOT NULL DEFAULT '{casual}',
    visual_weight         TEXT CHECK (visual_weight IN ('light', 'medium', 'heavy')),
    wear_count            INTEGER NOT NULL DEFAULT 0,
    last_worn_at          TIMESTAMPTZ,
    is_archived           BOOLEAN NOT NULL DEFAULT FALSE,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_wardrobe_items_user ON wardrobe_items (user_id);
CREATE INDEX idx_wardrobe_items_user_category ON wardrobe_items (user_id, category, is_archived);

ALTER TABLE wardrobe_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can CRUD own items" ON wardrobe_items FOR ALL USING (auth.uid() = user_id);

CREATE TRIGGER wardrobe_items_updated_at
    BEFORE UPDATE ON wardrobe_items
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- ITEM STYLE TAGS
-- ============================================================
CREATE TABLE item_style_tags (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    wardrobe_item_id      UUID NOT NULL REFERENCES wardrobe_items(id) ON DELETE CASCADE,
    tag                   TEXT NOT NULL,
    confidence            NUMERIC(3,2) NOT NULL DEFAULT 1.00,
    source                TEXT NOT NULL DEFAULT 'auto' CHECK (source IN ('auto', 'user', 'engine'))
);

CREATE INDEX idx_item_style_tags_item ON item_style_tags (wardrobe_item_id);
CREATE UNIQUE INDEX idx_item_style_tags_unique ON item_style_tags (wardrobe_item_id, tag);

ALTER TABLE item_style_tags ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can access own item tags" ON item_style_tags FOR ALL
    USING (EXISTS (
        SELECT 1 FROM wardrobe_items
        WHERE wardrobe_items.id = item_style_tags.wardrobe_item_id
        AND wardrobe_items.user_id = auth.uid()
    ));

-- ============================================================
-- STYLE ARCHETYPES (seed data, read-only for users)
-- ============================================================
CREATE TABLE style_archetypes (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                     TEXT NOT NULL UNIQUE,
    family                   TEXT NOT NULL,
    editorial_name           TEXT NOT NULL,
    description              TEXT,
    formality_min            NUMERIC(3,1) NOT NULL DEFAULT 1.0,
    formality_max            NUMERIC(3,1) NOT NULL DEFAULT 10.0,
    seasons                  TEXT[] NOT NULL DEFAULT '{spring,summer,fall,winter}',
    occasions                TEXT[] NOT NULL DEFAULT '{casual}',
    mood_keywords            TEXT[] NOT NULL DEFAULT '{}',
    color_preferences        JSONB,
    texture_preferences      JSONB,
    proportion_preferences   JSONB
);

ALTER TABLE style_archetypes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated users can read archetypes" ON style_archetypes
    FOR SELECT USING (auth.role() = 'authenticated');

-- ============================================================
-- STYLE RULES (seed data, read-only for users)
-- ============================================================
CREATE TABLE style_rules (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    archetype_id          UUID NOT NULL REFERENCES style_archetypes(id) ON DELETE CASCADE,
    slot_requirements     JSONB NOT NULL,
    weight                NUMERIC(4,2) NOT NULL DEFAULT 1.00,
    boost_conditions      JSONB,
    penalty_conditions    JSONB,
    preferred_harmony     TEXT NOT NULL DEFAULT 'neutral',
    proportion_rule       JSONB,
    texture_rule          JSONB
);

CREATE INDEX idx_style_rules_archetype ON style_rules (archetype_id);

ALTER TABLE style_rules ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated users can read rules" ON style_rules
    FOR SELECT USING (auth.role() = 'authenticated');

-- ============================================================
-- OUTFITS
-- ============================================================
CREATE TABLE outfits (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                  UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    archetype_id             UUID NOT NULL REFERENCES style_archetypes(id),
    editorial_name           TEXT NOT NULL,
    editorial_description    TEXT,
    date                     DATE NOT NULL,
    score                    NUMERIC(5,2) NOT NULL,
    score_breakdown          JSONB,
    reaction                 TEXT CHECK (reaction IN ('love', 'like', 'skip')),
    is_worn                  BOOLEAN NOT NULL DEFAULT FALSE,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_outfits_user_date ON outfits (user_id, date);

ALTER TABLE outfits ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can CRUD own outfits" ON outfits FOR ALL USING (auth.uid() = user_id);

-- ============================================================
-- OUTFIT SLOTS
-- ============================================================
CREATE TABLE outfit_slots (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    outfit_id             UUID NOT NULL REFERENCES outfits(id) ON DELETE CASCADE,
    wardrobe_item_id      UUID NOT NULL REFERENCES wardrobe_items(id) ON DELETE CASCADE,
    slot_name             TEXT NOT NULL,
    role                  TEXT NOT NULL DEFAULT 'supporting' CHECK (role IN ('hero', 'supporting', 'completing'))
);

CREATE INDEX idx_outfit_slots_outfit ON outfit_slots (outfit_id);

ALTER TABLE outfit_slots ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can access own outfit slots" ON outfit_slots FOR ALL
    USING (EXISTS (
        SELECT 1 FROM outfits
        WHERE outfits.id = outfit_slots.outfit_id
        AND outfits.user_id = auth.uid()
    ));

-- ============================================================
-- STORAGE BUCKET POLICY (applied via Supabase dashboard)
-- ============================================================
-- Bucket: wardrobe-images (private)
-- Upload policy: authenticated users can upload to their own folder
--   bucket_id = 'wardrobe-images' AND auth.uid()::text = (storage.foldername(name))[1]
-- Read policy: authenticated users can read their own folder
--   bucket_id = 'wardrobe-images' AND auth.uid()::text = (storage.foldername(name))[1]
-- Delete policy: same as read

-- ============================================================
-- FORMALITY COMPUTATION FUNCTION
-- ============================================================
CREATE OR REPLACE FUNCTION compute_formality(components JSONB)
RETURNS NUMERIC AS $$
BEGIN
    RETURN ROUND(
        (COALESCE((components->>'color_brightness')::NUMERIC, 5) * 0.25 +
         COALESCE((components->>'texture_smoothness')::NUMERIC, 5) * 0.30 +
         COALESCE((components->>'pattern_scale')::NUMERIC, 5) * 0.15 +
         COALESCE((components->>'structural_score')::NUMERIC, 5) * 0.30),
        1
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Auto-compute formality when components change
CREATE OR REPLACE FUNCTION auto_compute_formality()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.formality_components IS NOT NULL THEN
        NEW.formality_computed = compute_formality(NEW.formality_components);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER wardrobe_items_compute_formality
    BEFORE INSERT OR UPDATE OF formality_components ON wardrobe_items
    FOR EACH ROW EXECUTE FUNCTION auto_compute_formality();
