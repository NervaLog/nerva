SET search_path TO ${nerva}, extensions;

DO
$$
    BEGIN
        -- Event types for different notification sources
        IF to_regtype('${nerva}.event_type') IS NULL THEN
            CREATE TYPE event_type AS ENUM (
                'calendar_event',
                'email_received',
                'slack_message',
                'github_notification',
                'task_due',
                'meeting_reminder',
                'generic'
            );
        END IF;

        -- Attention kinds represent the urgency/priority level
        IF to_regtype('${nerva}.attention_kind') IS NULL THEN
            CREATE TYPE attention_kind AS ENUM (
                'immediate',    -- Requires immediate attention
                'soon',         -- Should be addressed within hours
                'batch',        -- Can be batched with similar items
                'info'          -- Informational only
            );
        END IF;

        -- Attention status tracks the lifecycle of an attention item
        IF to_regtype('${nerva}.attention_status') IS NULL THEN
            CREATE TYPE attention_status AS ENUM (
                'pending',      -- Awaiting delivery
                'delivered',    -- Push sent successfully
                'dismissed',    -- User dismissed
                'actioned',     -- User took action
                'expired'       -- TTL expired without action
            );
        END IF;
    END
$$;
