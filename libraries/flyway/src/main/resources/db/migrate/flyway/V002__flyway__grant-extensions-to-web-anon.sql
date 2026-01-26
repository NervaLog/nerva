-- Grant usage on extensions schema to web_anon
-- Required for stored functions that set search_path to include extensions
GRANT USAGE ON SCHEMA extensions TO web_anon;
