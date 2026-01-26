SET SEARCH_PATH TO ${iam}, extensions;

-- Fix the foreign key constraints on org_membership
-- They were accidentally swapped (org_id referenced users, user_id referenced orgs)

ALTER TABLE org_membership
    DROP CONSTRAINT IF EXISTS org_membership_org_id_fkey,
    DROP CONSTRAINT IF EXISTS org_membership_user_id_fkey;

ALTER TABLE org_membership
    ADD CONSTRAINT org_membership_org_id_fkey
        FOREIGN KEY (org_id) REFERENCES orgs (id) ON DELETE CASCADE,
    ADD CONSTRAINT org_membership_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE;
