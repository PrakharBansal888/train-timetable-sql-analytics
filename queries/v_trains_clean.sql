-- =====================================================================
-- POWER BI DATA MODEL VIEW: v_trains_clean
-- Purpose: Pre-computes dimensional attributes, standardized corridor names,
-- calculated speed, and operational weekly weights for Power BI consumption.
-- =====================================================================

USE trains_db;

CREATE OR REPLACE VIEW v_trains_clean AS
SELECT 
    train_no,
    train_name,
    COALESCE(NULLIF(train_type, ''), 'Standard') AS train_type,
    from_stn,
    pf_from,
    dep_time,
    CAST(SUBSTRING_INDEX(dep_time, ':', 1) AS UNSIGNED) AS dep_hour,
    to_stn,
    pf_to,
    arr_time,
    duration AS duration_mins,
    halts,
    distance_km,
    ROUND(distance_km / (duration / 60.0), 1) AS speed_kmh,
    days,
    LENGTH(REPLACE(days, '.', '')) AS runs_per_week,
    CASE 
        WHEN days NOT LIKE '%.%' THEN 'Daily'
        ELSE 'Weekly / Periodic'
    END AS service_frequency,
    classes,
    source_file,
    CASE 
        WHEN source_file LIKE '%ADI%' THEN 'Vadodara - Ahmedabad'
        WHEN source_file LIKE '%MMCT%' THEN 'Vadodara - Mumbai Central'
        WHEN source_file LIKE '%RTM%' THEN 'Vadodara - Ratlam'
        WHEN source_file LIKE '%EKNR%' THEN 'Vadodara - Ekta Nagar'
        ELSE 'Other'
    END AS corridor
FROM trains;
