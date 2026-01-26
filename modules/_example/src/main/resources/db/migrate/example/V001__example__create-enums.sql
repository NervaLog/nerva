-- Example enum - must be synchronized with Kotlin enum
-- See: dev.template.example.enums.ThingStatus

DO $$
BEGIN
    CREATE TYPE ${example}.thing_status AS ENUM ('draft', 'active', 'archived');
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;
