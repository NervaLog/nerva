SET search_path TO ${nerva}, extensions;

-- Render attention item as push notification payload
-- Returns: JSON suitable for FCM/APNS
CREATE OR REPLACE FUNCTION render_attention_payload(
    p_attention_id uuid
) RETURNS jsonb AS
$$
DECLARE
    v_attention record;
    v_payload jsonb;
BEGIN
    -- Fetch attention item
    SELECT * INTO v_attention
    FROM attention_projection
    WHERE id = p_attention_id;

    IF v_attention IS NULL THEN
        RETURN jsonb_build_object('error', 'attention_not_found');
    END IF;

    -- Build notification payload
    v_payload := jsonb_build_object(
        'notification', jsonb_build_object(
            'title', v_attention.title,
            'body', COALESCE(v_attention.body, '')
        ),
        'data', jsonb_build_object(
            'attention_id', v_attention.id,
            'attention_kind', v_attention.attention_kind,
            'event_count', v_attention.event_count,
            'deeplink_url', v_attention.deeplink_url
        ),
        'android', jsonb_build_object(
            'priority', CASE v_attention.attention_kind
                WHEN 'immediate' THEN 'high'
                WHEN 'soon' THEN 'high'
                ELSE 'normal'
            END,
            'collapse_key', v_attention.attention_id
        ),
        'apns', jsonb_build_object(
            'headers', jsonb_build_object(
                'apns-priority', CASE v_attention.attention_kind
                    WHEN 'immediate' THEN '10'
                    WHEN 'soon' THEN '10'
                    ELSE '5'
                END,
                'apns-collapse-id', v_attention.attention_id
            )
        )
    );

    RETURN v_payload;
END;
$$ LANGUAGE plpgsql;

-- Grant execute
GRANT EXECUTE ON FUNCTION render_attention_payload TO authenticated;
