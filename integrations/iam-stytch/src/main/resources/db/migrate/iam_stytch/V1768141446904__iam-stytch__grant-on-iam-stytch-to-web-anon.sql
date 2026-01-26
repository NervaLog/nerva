grant usage on schema ${iam_stytch} to web_anon;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA ${iam_stytch} TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA ${iam_stytch} GRANT SELECT, INSERT, UPDATE ON TABLES TO web_anon;
