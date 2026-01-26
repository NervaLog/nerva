create role web_anon nologin;
grant usage on schema ${iam} to web_anon;
create role authenticator noinherit login password 'mysecretpassword';
grant web_anon to authenticator;

SET SEARCH_PATH TO ${iam}, extensions;

grant all privileges on
    ${iam.user_table},
    ${iam.org_table},
    ${iam.org_membership_table},
    ${iam.user_identities_table}
    to web_anon;


