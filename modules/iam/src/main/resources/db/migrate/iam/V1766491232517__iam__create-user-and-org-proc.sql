SET SEARCH_PATH TO ${iam}, extensions;

CREATE OR REPLACE FUNCTION create_user_and_org(
    provider auth_provider,
    provider_subject text,
    email text,
    first_name text,
    org_slug text,
    role org_role DEFAULT 'owner',
    is_primary_owner boolean DEFAULT true
) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ${iam}, extensions
AS
$$
DECLARE
    v_result jsonb;
BEGIN
    -- 1. Upsert the User (Profile)
    -- Note: We use email as the conflict target if provider_user_id is removed from your user table,
    -- or keep your previous logic if provider_user_id is still the primary key.
    WITH upsert_user AS (
        INSERT INTO users (email, first_name)
            VALUES (email, first_name)
            ON CONFLICT (email) DO UPDATE
                SET first_name = COALESCE(EXCLUDED.first_name, users.first_name),
                    updated_at = now()
            RETURNING id, email, first_name, status),

         -- 2. Upsert the Identity (The specific auth method)
         upsert_identity AS (
             INSERT INTO identities (user_id, provider, provider_subject, email_at_auth)
                 SELECT id, provider, provider_subject, email FROM upsert_user
                 ON CONFLICT (provider, provider_subject) DO UPDATE
                     SET last_used_at = now()
                 RETURNING user_id),

         -- 3. Upsert the Organization
         upsert_org AS (
             INSERT INTO orgs (slug)
                 VALUES (org_slug)
                 ON CONFLICT (slug) DO UPDATE
                     SET updated_at = now()
                 RETURNING id, slug),

         -- 4. Upsert the Membership
         upsert_membership AS (
             INSERT INTO org_membership (org_id, user_id, role, is_primary_owner)
                 SELECT o.id, u.id, role, is_primary_owner
                 FROM upsert_org o,
                      upsert_user u
                 ON CONFLICT (org_id, user_id) DO UPDATE
                     SET role = EXCLUDED.role,
                         is_primary_owner = EXCLUDED.is_primary_owner
                 RETURNING org_id, user_id, role, is_primary_owner)

    -- 5. Construct final JSON response
    SELECT jsonb_build_object(
                   'id', u.id,
                   'email', u.email,
                   'first_namer', u.first_name,
                   'status', u.status,
                   'org_membership', jsonb_build_array(
                           jsonb_build_object(
                                   'org_role', um.role,
                                   'is_primary_owner', um.is_primary_owner,
                                   'organization', jsonb_build_object(
                                           'id', o.id,
                                           'slug', o.slug
                                                   )
                           )
                                     )
           )
    INTO v_result
    FROM upsert_membership um
             JOIN upsert_user u ON u.id = um.user_id
             JOIN upsert_org o ON o.id = um.org_id;

    RETURN v_result;
END;
$$;

