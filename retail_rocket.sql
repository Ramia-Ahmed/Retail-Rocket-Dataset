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
    