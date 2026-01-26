-- Grant full access to web_anon for development/testing
-- In production, use RLS policies to restrict access

SET search_path TO ${nerva};

-- Tables: full read/write access
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA ${nerva} TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA ${nerva} GRANT SELECT, INSERT, UPDATE ON TABLES TO web_anon;

-- Functions: execute access
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ${nerva} TO web_anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA ${nerva} GRANT EXECUTE ON FUNCTIONS TO web_anon;

-- Also grant to authenticated role
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA ${nerva} TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA ${nerva} GRANT SELECT, INSERT, UPDATE ON TABLES TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ${nerva} TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA ${nerva} GRANT EXECUTE ON FUNCTIONS TO authenticated;
