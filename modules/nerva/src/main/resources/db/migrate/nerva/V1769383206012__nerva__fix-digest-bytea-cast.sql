SET search_path TO ${nerva}, extensions;

-- Fix digest() calls: digest expects (bytea, text) but we were passing (text, text)
-- This affected both ingest_event and validate_api_key functions

-- Fix ingest_event
CREATE OR REPLACE FUNCTION ingest_event(
    p_org_id uuid,
    p_provider text,
    p_external_id text,
    p_event_type event_type,
    p_payload jsonb DEFAULT '{}',
    p_occurred_at timestamptz DEFAULT now(),
    -- Collapse configuration
    p_collapse_key text DEFAULT NULL,
    p_collapse_window_minutes int DEFAULT 5,
    -- Attention configuration
    p_attention_kind attention_kind DEFAULT 'batch',
    p_title text DEFAULT NULL,
    p_body text DEFAULT NULL,
    p_deeplink_url text DEFAULT NULL,
    p_expires_at timestamptz DEFAULT NULL
) RETURNS jsonb AS
$$
DECLARE
    v_event_id uuid;
    v_was_created boolean := false;
    v_attention_id text;
    v_attention_uuid uuid;
    v_job_id uuid;
    v_window_start timestamptz;
    v_collapse_components text;
    v_occurred timestamptz;
    v_payload_value jsonb;
BEGIN
    -- Handle NULL values explicitly
    v_occurred := COALESCE(p_occurred_at, now());
    v_payload_value := COALESCE(p_payload, '{}');

    -- Step 1: Insert event with ON CONFLICT for idempotency
    INSERT INTO events (org_id, provider, external_id, event_type, payload, occurred_at)
    VALUES (p_org_id, p_provider, p_external_id, p_event_type, v_payload_value, v_occurred)
    ON CONFLICT (org_id, provider, external_id) DO NOTHING
    RETURNING id INTO v_event_id;

    -- Check if event was newly created
    IF v_event_id IS NOT NULL THEN
        v_was_created := true;
    ELSE
        -- Get existing event ID
        SELECT id INTO v_event_id
        FROM events
        WHERE org_id = p_org_id AND provider = p_provider AND external_id = p_external_id;

        -- Return early - event already processed
        RETURN jsonb_build_object(
            'event_id', v_event_id,
            'attention_id', NULL,
            'was_created', false,
            'job_id', NULL
        );
    END IF;

    -- Step 2: Calculate collapse window and deterministic attention_id
    v_window_start := date_trunc('minute', v_occurred) -
                      (EXTRACT(minute FROM v_occurred)::int % p_collapse_window_minutes) * interval '1 minute';

    -- Build collapse components for deterministic ID
    v_collapse_components := p_org_id::text || '|' ||
                             COALESCE(p_collapse_key, p_provider || '|' || p_event_type::text) || '|' ||
                             v_window_start::text;

    -- FIX: Use fully qualified function name and cast types properly
    v_attention_id := encode(extensions.digest(v_collapse_components::bytea, 'sha256'::text), 'hex');

    -- Step 3: Upsert attention projection
    INSERT INTO attention_projection (
        org_id,
        attention_id,
        attention_kind,
        title,
        body,
        deeplink_url,
        event_count,
        first_event_at,
        last_event_at,
        event_ids,
        expires_at
    )
    VALUES (
        p_org_id,
        v_attention_id,
        p_attention_kind,
        COALESCE(p_title, 'New ' || p_event_type::text),
        p_body,
        p_deeplink_url,
        1,
        v_occurred,
        v_occurred,
        ARRAY[v_event_id],
        p_expires_at
    )
    ON CONFLICT (org_id, attention_id) DO UPDATE SET
        event_count = attention_projection.event_count + 1,
        last_event_at = GREATEST(attention_projection.last_event_at, EXCLUDED.last_event_at),
        event_ids = array_append(attention_projection.event_ids, v_event_id),
        updated_at = now(),
        title = CASE
            WHEN EXCLUDED.attention_kind < attention_projection.attention_kind THEN EXCLUDED.title
            ELSE attention_projection.title
        END,
        body = CASE
            WHEN EXCLUDED.attention_kind < attention_projection.attention_kind THEN EXCLUDED.body
            ELSE attention_projection.body
        END,
        attention_kind = LEAST(EXCLUDED.attention_kind, attention_projection.attention_kind)
    RETURNING id INTO v_attention_uuid;

    -- Step 4: Enqueue delivery job
    SELECT ${jobs}.enqueue_job(
        p_job_type := 'deliver_attention',
        p_target_type := 'attention_projection',
        p_target_id := v_attention_uuid,
        p_idempotency_key := 'deliver_' || v_attention_id,
        p_priority := CASE p_attention_kind
            WHEN 'immediate' THEN 100
            WHEN 'soon' THEN 50
            WHEN 'batch' THEN 10
            ELSE 0
        END,
        p_available_at := CASE p_attention_kind
            WHEN 'immediate' THEN now()
            WHEN 'soon' THEN now() + interval '5 minutes'
            WHEN 'batch' THEN now() + interval '30 minutes'
            ELSE now() + interval '1 hour'
        END
    ) INTO v_job_id;

    RETURN jsonb_build_object(
        'event_id', v_event_id,
        'attention_id', v_attention_uuid,
        'was_created', v_was_created,
        'job_id', v_job_id
    );
END;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION ingest_event TO web_anon;
GRANT EXECUTE ON FUNCTION ingest_event TO authenticated;

-- Fix validate_api_key
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
    -- FIX: Use fully qualified function name and cast types properly
    v_key_hash := encode(extensions.digest(p_api_key::bytea, 'sha256'::text), 'hex');

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

GRANT EXECUTE ON FUNCTION validate_api_key TO web_anon;
GRANT EXECUTE ON FUNCTION validate_api_key TO authenticated;
