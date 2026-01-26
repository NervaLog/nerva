-- Create the nerva schema
CREATE SCHEMA IF NOT EXISTS nerva;

-- Grant usage to PostgREST roles
GRANT USAGE ON SCHEMA nerva TO web_anon;
GRANT USAGE ON SCHEMA nerva TO authenticated;
