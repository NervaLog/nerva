SET SEARCH_PATH TO ${example}, extensions;

CREATE TABLE IF NOT EXISTS things (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    status thing_status NOT NULL DEFAULT 'draft',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Example stored procedure
CREATE OR REPLACE FUNCTION create_thing(
    p_name TEXT
) RETURNS JSONB
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = ${example}, extensions
AS $$
DECLARE
    v_thing things;
BEGIN
    INSERT INTO things (name, status)
    VALUES (p_name, 'draft')
    RETURNING * INTO v_thing;

    RETURN jsonb_build_object(
        'id', v_thing.id,
        'name', v_thing.name,
        'status', v_thing.status
    );
END;
$$;
