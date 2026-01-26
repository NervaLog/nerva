SET search_path TO ${iam}, extensions;

DO
$$
    BEGIN
        IF to_regtype('${iam}.org_role') IS NULL THEN
            CREATE TYPE org_role AS ENUM ('owner', 'admin', 'member', 'viewer');
        END IF;

        IF to_regtype('${iam}.org_status') IS NULL THEN
            CREATE TYPE org_status AS ENUM ('active', 'suspended', 'deleted');
        END IF;

        IF to_regtype('${iam}.user_status') IS NULL THEN
            CREATE TYPE user_status AS ENUM ('active', 'disabled', 'deleted');
        END IF;

        IF to_regtype('${iam}.auth_provider') IS NULL THEN
            CREATE TYPE auth_provider AS ENUM (
                'stytch_magic_link', 'stytch_google', 'stytch_microsoft', 'sso_saml', 'sso_oidc'
                );
        END IF;
    END
$$;
