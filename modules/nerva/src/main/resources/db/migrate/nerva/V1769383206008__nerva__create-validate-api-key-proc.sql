SET search_path TO ${nerva}, extensions;

-- Validate an API key and return org_id if valid
-- Returns: JSON with valid, org_id, key_id, scopes
CREATE OR REPLACE FUNCTION validate_api_key(
    p_api_key text
) RETURNS jsonb AS
$$
DECLARE
    v_key_prefix text;
    v_key_hash text;
    v_result record;
BEGIN
    -- Extract prefix (first 11 chars: 'nv_' + 8 chars)
    IF p_api_key IS NULL OR length(p_api_key) < 12 THEN
        RETURN jsonb_build_object('valid', false, 'error', 'invalid_key_format');
    END IF;

    v_key_prefix := substring(p_api_key, 1, 11);
    v_key_hash := encode(digest(p_api_key, 'sha256'), 'hex');

    -- Look up key by prefix and verify hash
    SELECT ak.id, ak.org_id, ak.scopes, ak.expires_at, ak.revoked_at
    INTO v_result
    FROM api_keys ak
    WHERE ak.key_prefix = v_key_prefix
      AND ak.key_hash = v_key_hash
    LIMIT 1;

    -- Key not found
    IF v_result IS NULL THEN
        RETURN jsonb_build_object('valid', false, 'error', 'key_not_found');
    END IF;

    -- Key revoked
    IF v_result.revoked_at IS NOT NULL THEN
        RETURN jsonb_build_object('valid', false, 'error', 'key_revoked');
    END IF;

    -- Key expired
    IF v_result.expires_at IS NOT NULL AND v_result.expires_at < now() THEN
        RETURN jsonb_build_object('valid', false, 'error', 'key_expired');
    END IF;

    -- Update last_used_at
    UPDATE api_keys SET last_used_at = now() WHERE id = v_result.id;

    RETURN jsonb_build_object(
        'valid', true,
        'org_id', v_result.org_id,
        'key_id', v_result.id,
        'scopes', v_result.scopes
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute to web_anon (needed for initial auth check)
GRANT EXECUTE ON FUNCTION validate_api_key TO web_anon;
GRANT EXECUTE ON FUNCTION validate_api_key TO authenticated;
