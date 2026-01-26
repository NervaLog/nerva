-- Core
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA extensions;

-- Search
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;

-- Geo (PostGIS)
-- CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA extensions;

-- Better inverted index option for certain FTS workloads
-- CREATE EXTENSION IF NOT EXISTS rum WITH SCHEMA extensions;