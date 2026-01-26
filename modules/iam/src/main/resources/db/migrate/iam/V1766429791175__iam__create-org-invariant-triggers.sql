SET SEARCH_PATH TO ${iam}, extensions;

-- 1. Updated_at automation
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS
$$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_touch
    BEFORE UPDATE
    ON users
    FOR EACH ROW
EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_orgs_touch
    BEFORE UPDATE
    ON orgs
    FOR EACH ROW
EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_identities_touch
    BEFORE UPDATE
    ON identities
    FOR EACH ROW
EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_membership_touch
    BEFORE UPDATE
    ON org_membership
    FOR EACH ROW
EXECUTE FUNCTION touch_updated_at();

-- 2. Owner Role Invariant
CREATE OR REPLACE FUNCTION enforce_org_owner_invariants() RETURNS trigger AS
$$
BEGIN
    IF NEW.is_primary_owner AND NEW.role <> 'owner'::org_role THEN
        RAISE EXCEPTION 'A primary owner must have the owner role.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_org_owner_invariants
    BEFORE INSERT OR UPDATE
    ON org_membership
    FOR EACH ROW
EXECUTE FUNCTION enforce_org_owner_invariants();