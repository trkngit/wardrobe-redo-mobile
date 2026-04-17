-- 00003_add_check_constraints.sql
-- Adds CHECK constraints to prevent invalid data from corrupting scoring and display.
-- These constraints enforce domain rules that were only validated in Swift code.

-- Outfit score must be between 0 and 1 (percentage as decimal)
ALTER TABLE outfits
    ADD CONSTRAINT chk_outfit_score CHECK (score >= 0 AND score <= 1);

-- Wear count cannot be negative
ALTER TABLE wardrobe_items
    ADD CONSTRAINT chk_wear_count CHECK (wear_count >= 0);

-- Formality is on a 0-10 scale
ALTER TABLE wardrobe_items
    ADD CONSTRAINT chk_formality_computed CHECK (
        formality_computed IS NULL OR (formality_computed >= 0 AND formality_computed <= 10)
    );

-- Style tag confidence must be between 0 and 1
ALTER TABLE item_style_tags
    ADD CONSTRAINT chk_tag_confidence CHECK (
        confidence IS NULL OR (confidence >= 0 AND confidence <= 1)
    );

-- Archetype formality range must be ordered (min <= max)
ALTER TABLE style_archetypes
    ADD CONSTRAINT chk_formality_range CHECK (formality_min <= formality_max);
