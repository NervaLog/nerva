SET search_path TO ${iam_stytch}, extensions;

-- Add request_id column to track Stytch's request ID for debugging/tracing
ALTER TABLE discovery_requests
    ADD COLUMN IF NOT EXISTS request_id text;
