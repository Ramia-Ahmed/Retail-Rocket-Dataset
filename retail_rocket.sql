CREATE OR REPLACE VIEW category_tree AS
SELECT * FROM 'Archive/category_tree.csv';

CREATE OR REPLACE VIEW events AS
SELECT * FROM 'Archive/events.csv';

CREATE OR REPLACE VIEW item_properties AS
SELECT * FROM 'Archive/item_properties*.csv';

SELECT * FROM category_tree;
SELECT * FROM events;
SELECT * FROM item_properties;

SELECT event, COUNT(*) AS count
FROM events
GROUP BY event
ORDER BY count;

SELECT visitorid, count(*) AS event_count
FROM events
GROUP BY visitorid
ORDER BY event_count DESC
LIMIT 5;

SELECT
    visitorid,
    event,
    itemid,
    to_timestamp(timestamp / 1000) AS event_time
FROM events
WHERE visitorid = 1150086
ORDER BY timestamp;

SELECT
    visitorid,
    event,
    itemid,
    event_time,
    DATE_DIFF('second', LAG(event_time) OVER
    (
        PARTITION BY visitorid 
        ORDER BY event_time
    ), event_time) AS gap_sec FROM
    (
    SELECT
        visitorid,
        event,
        itemid,
        to_timestamp(timestamp / 1000) AS event_time
    FROM events
    WHERE visitorid = 1150086
    )
ORDER BY event_time;

WITH gaps AS (
    SELECT
        visitorid,
        to_timestamp(timestamp / 1000) AS event_time,
        DATE_DIFF('second',
        LAG(to_timestamp(timestamp / 1000))
        OVER
        (
            PARTITION BY visitorid
            ORDER BY timestamp
        ), to_timestamp(timestamp / 1000)
        ) AS gap
    FROM events
)
SELECT
    MIN(gap) AS min_gap,
    MAX(gap) AS max_gap,
    APPROX_QUANTILE(gap, 0.5) AS median_gap,
    APPROX_QUANTILE(gap, 0.9) AS p90_gap,
    APPROX_QUANTILE(gap, 0.99) AS p99_gap
FROM gaps
WHERE gap IS NOT NULL;

CREATE OR REPLACE VIEW events_with_sessions AS
WITH gaps AS (
    SELECT
        visitorid,
        event,
        itemid,
        transactionid,
        to_timestamp(timestamp / 1000) AS event_time,
        DATE_DIFF('second',
        LAG(to_timestamp(timestamp / 1000))
        OVER
        (
            PARTITION BY visitorid
            ORDER BY timestamp
        ), to_timestamp(timestamp / 1000)
        ) AS gap
    FROM events
),
session_flags AS
(
    SELECT *,
    CASE
        WHEN gap IS NULL OR gap > 1800 THEN 1
        ELSE 0
    END AS is_new_session
    FROM gaps
)
SELECT 
    visitorid,
    event,
    itemid,
    transactionid,
    event_time,
    gap,
    SUM(is_new_session) OVER
    (
        PARTITION BY visitorid
        ORDER BY event_time
    ) AS session_num
FROM session_flags
ORDER BY visitorid, event_time;

SELECT 
    visitorid, 
    event, 
    event_time, 
    gap, 
    session_num
FROM events_with_sessions
WHERE visitorid = 1150086
ORDER BY event_time
LIMIT 30;

CREATE OR REPLACE VIEW session_funnel AS
SELECT
    visitorid,
    session_num,
    MAX(
    CASE
        WHEN event = 'view' THEN 1
        ELSE 0
    END
    ) AS had_view,
    MAX(
    CASE
        WHEN event = 'addtocart' THEN 1
        ELSE 0
    END
    ) AS had_addtocart,
    MAX(
    CASE
        WHEN event = 'transaction' THEN 1
        ELSE 0
    END
    ) AS had_transaction
FROM events_with_sessions
GROUP BY 
    visitorid,
    session_num;
CREATE OR REPLACE VIEW car AS
SELECT
    SUM(had_addtocart) AS sessions_with_cart,
    SUM(
    CASE
        WHEN had_addtocart = 1
        AND had_transaction = 1
        THEN 1
        ELSE 0
    END
    ) AS sessions_with_purchase,
    ROUND(1 - (sessions_with_purchase * 1.0/sessions_with_cart), 2) AS cart_abandonment_rate
FROM session_funnel;

CREATE OR REPLACE VIEW car_by_week AS
WITH session_time AS (
SELECT
    visitorid,
    session_num,
    MIN(event_time) AS session_start
FROM events_with_sessions
GROUP BY 
    visitorid,
    session_num
),
weekly_funnel AS(
    SELECT
    DATE_TRUNC('week', st.session_start) AS week,
    sf.had_addtocart,
    sf.had_transaction
    FROM session_funnel sf
    JOIN session_time st
        ON sf.visitorid = st.visitorid
        AND sf.session_num = st.session_num
    WHERE sf.had_addtocart = 1
)
SELECT 
    week,
    SUM(had_addtocart) AS sessions_with_cart,
    SUM(
    CASE
        WHEN had_addtocart = 1
        AND had_transaction = 1
        THEN 1
        ELSE 0
    END
    ) AS sessions_with_purchase,
    ROUND(1 - (sessions_with_purchase * 1.0/sessions_with_cart), 2) AS cart_abandonment_rate
FROM weekly_funnel
GROUP BY week 
ORDER BY week;

CREATE OR REPLACE VIEW car_by_month AS
WITH session_time AS (
SELECT
    visitorid,
    session_num,
    MIN(event_time) AS session_start
FROM events_with_sessions
GROUP BY 
    visitorid,
    session_num
),
monthly_funnel AS(
    SELECT
    DATE_TRUNC('month', st.session_start) AS month,
    sf.had_addtocart,
    sf.had_transaction
    FROM session_funnel sf
    JOIN session_time st
        ON sf.visitorid = st.visitorid
        AND sf.session_num = st.session_num
    WHERE sf.had_addtocart = 1
)
SELECT 
    month,
    SUM(had_addtocart) AS sessions_with_cart,
    SUM(
    CASE
        WHEN had_addtocart = 1
        AND had_transaction = 1
        THEN 1
        ELSE 0
    END
    ) AS sessions_with_purchase,
    ROUND(1 - (sessions_with_purchase * 1.0/sessions_with_cart), 2) AS cart_abandonment_rate
FROM monthly_funnel
GROUP BY month 
ORDER BY month;

CREATE OR REPLACE VIEW car_by_category AS
WITH first_cart_item AS (
    SELECT
        visitorid,
        session_num,
        itemid,
        event_time,
        ROW_NUMBER() OVER(
            PARTITION BY visitorid, session_num
            ORDER BY event_time
        ) AS rn
    FROM events_with_sessions
    WHERE event = 'addtocart'
),
session_item AS (
    SELECT
        visitorid,
        session_num,
        itemid,
        event_time
    FROM first_cart_item
    WHERE rn = 1
),
category_props AS (
    SELECT
        itemid,
        value AS categoryid,
        to_timestamp(timestamp / 1000) AS prop_time
    FROM item_properties
    WHERE property = 'categoryid'
),
joined AS (
    SELECT
        si.visitorid,
        si.session_num,
        cp.categoryid,
        ROW_NUMBER() OVER (
            PARTITION BY si.visitorid, si.session_num
            ORDER BY cp.prop_time DESC
        ) AS rn
    FROM session_item si
    JOIN category_props cp
        ON si.itemid = cp.itemid
        AND cp.prop_time <= si.event_time

),
session_category AS (
    SELECT
        visitorid,
        session_num,
        categoryid
    FROM joined
    WHERE rn = 1
)
SELECT
    sc.categoryid,
    SUM(sf.had_addtocart) AS sessions_with_cart,
    SUM(CASE WHEN sf.had_addtocart = 1 AND sf.had_transaction = 1 THEN 1 ELSE 0 END) AS sessions_with_purchase,
    ROUND(1 - (sessions_with_purchase * 1.0 / sessions_with_cart), 2) AS cart_abandonment_rate
FROM session_category sc
JOIN session_funnel sf
    ON sc.visitorid = sf.visitorid
    AND sc.session_num = sf.session_num
GROUP BY sc.categoryid
HAVING SUM(sf.had_addtocart) >= 100
ORDER BY sessions_with_cart DESC;

SELECT * FROM car;
SELECT * FROM car_by_week;
SELECT * FROM car_by_month;
SELECT * FROM car_by_category;

SELECT categoryid, sessions_with_cart, sessions_with_purchase, cart_abandonment_rate, 'highest' AS rank_group
 FROM car_by_category
 ORDER BY cart_abandonment_rate DESC
 LIMIT 10;

SELECT categoryid, sessions_with_cart, sessions_with_purchase, cart_abandonment_rate, 'lowest' AS rank_group
 FROM car_by_category
 ORDER BY cart_abandonment_rate ASC
 LIMIT 10;

WITH ranked AS (
    SELECT
        categoryid,
        sessions_with_cart,
        sessions_with_purchase,
        cart_abandonment_rate,
        ROW_NUMBER() OVER (ORDER BY cart_abandonment_rate DESC) AS rank_high,
        ROW_NUMBER() OVER (ORDER BY cart_abandonment_rate ASC) AS rank_low
    FROM car_by_category
)
SELECT categoryid, sessions_with_cart, sessions_with_purchase, cart_abandonment_rate,
       CASE WHEN rank_high <= 10 THEN 'highest' ELSE 'lowest' END AS rank_group
FROM ranked
WHERE rank_high <= 10 OR rank_low <= 10
ORDER BY cart_abandonment_rate DESC;

WITH ranked AS (
    SELECT
        categoryid,
        sessions_with_cart,
        sessions_with_purchase,
        cart_abandonment_rate,
        ROW_NUMBER() OVER (ORDER BY cart_abandonment_rate DESC) AS rank_high,
        ROW_NUMBER() OVER (ORDER BY cart_abandonment_rate ASC) AS rank_low
    FROM car_by_category
    WHERE sessions_with_cart >= 100
)
SELECT categoryid, sessions_with_cart, sessions_with_purchase, cart_abandonment_rate,
       CASE WHEN rank_high <= 10 THEN 'highest' ELSE 'lowest' END AS rank_group
FROM ranked
WHERE rank_high <= 10 OR rank_low <= 10
ORDER BY cart_abandonment_rate DESC;