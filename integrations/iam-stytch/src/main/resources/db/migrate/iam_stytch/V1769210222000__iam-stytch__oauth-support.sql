SET search_path TO ${iam_stytch}, extensions;

-- For OAuth discovery, email is provided by the OAuth provider during callback,
-- not upfront like magic links. Make it nullable.
ALTER TABLE discovery_requests
    ALTER COLUMN email DROP NOT NULL;

-- Track the auth provider for the discovery request
-- (magic_link, google_oauth, microsoft_oauth, etc.)
ALTER TABLE discovery_requests
    ADD COLUMN provider TEXT;

COMMENT ON COLUMN discovery_requests.provider IS 'Auth provider: magic_link, google_oauth, microsoft_oauth, etc.';
