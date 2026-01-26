-- Anonymous role for unauthenticated requests
create role web_anon nologin;
grant usage on schema public to web_anon;

-- Authenticated role for logged-in users
create role authenticated nologin;
grant usage on schema public to authenticated;

-- Authenticator role - PostgREST connects as this, then switches to web_anon or authenticated
create role authenticator noinherit login password 'mysecretpassword';
grant web_anon to authenticator;
grant authenticated to authenticator;