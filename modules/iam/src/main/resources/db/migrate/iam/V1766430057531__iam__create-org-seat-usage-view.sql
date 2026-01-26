SET SEARCH_PATH TO ${iam}, extensions;

CREATE OR REPLACE VIEW org_seat_usage AS
SELECT o.id                                                                  AS org_id,
       o.seats_limit,
       COUNT(m.user_id) FILTER (WHERE u.status = 'active')                   AS seats_used,
       (o.seats_limit - COUNT(m.user_id) FILTER (WHERE u.status = 'active')) AS seats_remaining
FROM orgs o
         LEFT JOIN org_membership m ON o.id = m.org_id
         LEFT JOIN users u ON m.user_id = u.id
GROUP BY o.id, o.seats_limit;