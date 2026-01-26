SET SEARCH_PATH TO ${iam}, extensions;

-- Fix parameter name clashes with column names by prefixing with p_
DROP FUNCTION IF EXISTS create_user_and_org(auth_provider, text, text, text, text, org_role, boolean);

CREATE OR REPLACE FUNCTION create_user_and_org(
    p_provider auth_provider,
    p_provider_subject text,
    p_email text,
    p_first_name text,
    p_org_slug text,
    p_role org_role DEFAULT 'owner',
    p_is_primary_owner boolean DEFAULT true
) RETURNS jsonb
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ${iam}, extensions
AS
$$
DECLARE
    v_result jsonb;
BEGIN
    WITH upsert_user AS (
        INSERT INTO users (email, first_name)
            VALUES (p_email, p_first_name)
            ON CONFLICT (email) DO UPDATE
                SET first_name = COALESCE(EXCLUDED.first_name, users.first_name),
                    updated_at = now()
            RETURNING id, email, first_name, status),

         upsert_identity AS (
             INSERT INTO identities (user_id, provider, provider_subject, email_at_auth)
                 SELECT id, p_provider, p_provider_subject, p_email FROM upsert_user
                 ON CONFLICT (provider, provider_subject) DO UPDATE
                     SET last_used_at = now()
                 RETURNING user_id),

         upsert_org AS (
             INSERT INTO orgs (slug, name)
                 VALUES (p_org_slug, p_org_slug)
                 ON CONFLICT (slug) DO UPDATE
                     SET updated_at = now()
                 RETURNING id, slug, name),

         upsert_membership AS (
             INSERT INTO org_membership (org_id, user_id, role, is_primary_owner)
                 SELECT o.id, u.id, p_role, p_is_primary_owner
                 FROM upsert_org o,
                      upsert_user u
                 ON CONFLICT (org_id, user_id) DO UPDATE
                     SET role = EXCLUDED.role,
                         is_primary_owner = EXCLUDED.is_primary_owner
                 RETURNING org_id, user_id, role, is_primary_owner)

    SELECT jsonb_build_object(
                   'id', u.id,
                   'email', u.email,
                   'first_name', u.first_name,
                   'status', u.status,
                   'org_membership', jsonb_build_array(
                           jsonb_build_object(
                                   'org_role', um.role,
                                   'is_primary_owner', um.is_primary_owner,
                                   'orgs', jsonb_build_object(
                                           'id', o.id,
                                           'slug', o.slug,
                                           'name', o.name
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

-- Explicitly grant EXECUTE to web_anon for this function
GRANT EXECUTE ON FUNCTION create_user_and_org(auth_provider, text, text, text, text, org_role, boolean) TO web_anon;
