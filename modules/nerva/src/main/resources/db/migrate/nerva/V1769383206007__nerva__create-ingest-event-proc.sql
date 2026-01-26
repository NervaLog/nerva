SET search_path TO ${nerva}, extensions;

-- Atomic event ingestion: event insert → projection upsert → job enqueue
-- Returns: JSON with event_id, attention_id, was_created, job_id
CREATE OR REPLACE FUNCTION ingest_event(
    p_org_id uuid,
    p_provider text,
    p_external_id text,
    p_event_type event_type,
    p_payload jsonb DEFAULT '{}',
    p_occurred_at timestamptz DEFAULT now(),
    -- Collapse configuration
    p_collapse_key text DEFAULT NULL,  -- Custom collapse key (if null, uses provider+type)
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
BEGIN
    -- Step 1: Insert event with ON CONFLICT for idempotency
    INSERT INTO events (org_id, provider, external_id, event_type, payload, occurred_at)
    VALUES (p_org_id, p_provider, p_external_id, p_event_type, p_payload, p_occurred_at)
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
    v_window_start := date_trunc('minute', p_occurred_at) -
                      (EXTRACT(minute FROM p_occurred_at)::int % p_collapse_window_minutes) * interval '1 minute';

    -- Build collapse components for deterministic ID
    v_collapse_components := p_org_id::text || '|' ||
                             COALESCE(p_collapse_key, p_provider || '|' || p_event_type::text) || '|' ||
                             v_window_start::text;

    v_attention_id := encode(digest(v_collapse_components, 'sha256'), 'hex');

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
        p_occurred_at,
        p_occurred_at,
        ARRAY[v_event_id],
        p_expires_at
    )
    ON CONFLICT (org_id, attention_id) DO UPDATE SET
        event_count = attention_projection.event_count + 1,
        last_event_at = GREATEST(attention_projection.last_event_at, EXCLUDED.last_event_at),
        event_ids = array_append(attention_projection.event_ids, v_event_id),
        updated_at = now(),
        -- Update content only if this is a higher priority event
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

    -- Step 4: Enqueue delivery job with idempotency
    -- Job type: deliver_attention, target: attention_projection
    -- Idempotency key ensures only one job per attention item in pending state
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

-- Grant execute to authenticated users
GRANT EXECUTE ON FUNCTION ingest_event TO authenticated;
