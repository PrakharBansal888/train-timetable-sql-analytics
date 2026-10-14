-- =====================================================================
-- INDIAN RAILWAYS ADVANCED CORRIDOR ANALYTICS (STATISTICALLY RIGOROUS)
-- Database: trains_db | Table: trains (364 records across 4 corridors)
-- Note on Data Scope: Timetables represent the first 118 departures per corridor
-- from IRI 5-page exports (ending at 15:30 for MMCT, 20:44 for ADI, 22:56 for RTM).
-- =====================================================================

USE trains_db;

-- ---------------------------------------------------------------------
-- QUERY 1: DEPARTURE HEADWAYS (Observed 00:41 - 20:44 Window on BRC -> ADI)
-- Business Question: What is the headway (time interval between consecutive
-- departures) on the Vadodara -> Ahmedabad mainline within the observed window?
-- Advanced Techniques: LAG() Window Function, TIMESTAMPDIFF, CTE
-- ---------------------------------------------------------------------
WITH departures_ranked AS (
    SELECT 
        train_no,
        train_name,
        train_type,
        from_stn,
        to_stn,
        dep_time,
        STR_TO_DATE(dep_time, '%H:%i') AS dep_dt,
        LAG(STR_TO_DATE(dep_time, '%H:%i')) OVER (
            PARTITION BY from_stn, to_stn 
            ORDER BY STR_TO_DATE(dep_time, '%H:%i')
        ) AS prev_dep_dt
    FROM trains
    WHERE from_stn = 'BRC' AND to_stn = 'ADI'
),
headway_metrics AS (
    SELECT 
        train_no,
        train_name,
        train_type,
        from_stn,
        to_stn,
        dep_time,
        TIMESTAMPDIFF(MINUTE, prev_dep_dt, dep_dt) AS headway_minutes
    FROM departures_ranked
    WHERE prev_dep_dt IS NOT NULL
)
SELECT 
    train_no,
    train_name,
    train_type,
    dep_time,
    headway_minutes,
    CASE 
        WHEN headway_minutes >= 120 THEN 'Gap >= 2 Hours'
        WHEN headway_minutes >= 60 THEN 'Gap 1 - 2 Hours'
        ELSE 'Frequent (< 1 Hour)'
    END AS headway_band
FROM headway_metrics
ORDER BY headway_minutes DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- QUERY 2: SPEED BENCHMARKING BY TRAIN CATEGORY (Filtered: N >= 3)
-- Business Question: How do train categories rank by average commercial speed,
-- filtering out single-service outliers (N >= 3)?
-- Advanced Techniques: Chained CTEs, DENSE_RANK() Window Function, HAVING filter
-- ---------------------------------------------------------------------
WITH train_speeds AS (
    SELECT 
        train_no,
        train_name,
        COALESCE(NULLIF(train_type, ''), 'Standard') AS train_type,
        distance_km,
        duration,
        ROUND(distance_km / (duration / 60.0), 1) AS speed_kmh
    FROM trains
    WHERE duration > 0 AND distance_km > 0
),
category_summary AS (
    SELECT 
        train_type,
        COUNT(*) AS service_count,
        ROUND(AVG(speed_kmh), 1) AS avg_speed_kmh,
        MIN(speed_kmh) AS min_speed_kmh,
        MAX(speed_kmh) AS max_speed_kmh
    FROM train_speeds
    GROUP BY train_type
    HAVING COUNT(*) >= 3
)
SELECT 
    train_type,
    service_count,
    avg_speed_kmh,
    min_speed_kmh,
    max_speed_kmh,
    DENSE_RANK() OVER (ORDER BY avg_speed_kmh DESC) AS speed_rank
FROM category_summary
ORDER BY speed_rank ASC;


-- ---------------------------------------------------------------------
-- QUERY 3: EMPIRICAL HALT PENALTY MODEL (OLS Linear Regression Slope)
-- Business Question: What is the empirical marginal time cost (minutes added
-- per additional halt) within comparable train categories (Superfast & Express)?
-- Statistical Formula: Cov(Halts, Duration) / Var(Halts)
-- Advanced Techniques: Mathematical aggregate OLS slope, Grouping by corridor
-- ---------------------------------------------------------------------
SELECT 
    CASE 
        WHEN source_file LIKE '%ADI%' THEN 'Vadodara - Ahmedabad'
        WHEN source_file LIKE '%MMCT%' THEN 'Vadodara - Mumbai Central'
        WHEN source_file LIKE '%RTM%' THEN 'Vadodara - Ratlam'
        WHEN source_file LIKE '%EKNR%' THEN 'Vadodara - Ekta Nagar'
    END AS corridor,
    COUNT(*) AS sample_size,
    ROUND(AVG(halts), 1) AS avg_halts,
    ROUND(AVG(duration), 1) AS avg_duration_mins,
    ROUND(
        (AVG(halts * duration) - AVG(halts) * AVG(duration))
        / NULLIF(AVG(halts * halts) - AVG(halts) * AVG(halts), 0),
        1
    ) AS mins_per_halt_slope
FROM trains
WHERE duration > 0 AND train_type IN ('SF', 'Exp')
GROUP BY source_file
ORDER BY mins_per_halt_slope DESC;


-- ---------------------------------------------------------------------
-- QUERY 4: ROUTE DURATION OUTLIER DETECTION (Empirical Variance)
-- Business Question: Which specific train services show the largest deviation
-- from their corridor's average transit duration?
-- Advanced Techniques: AVG() OVER (PARTITION BY ...), Variance %, CTE
-- ---------------------------------------------------------------------
WITH corridor_stats AS (
    SELECT 
        train_no,
        train_name,
        train_type,
        from_stn,
        to_stn,
        duration,
        ROUND(AVG(duration) OVER (PARTITION BY from_stn, to_stn), 1) AS corridor_avg_duration,
        ROUND(duration - AVG(duration) OVER (PARTITION BY from_stn, to_stn), 1) AS variance_mins,
        ROUND((duration - AVG(duration) OVER (PARTITION BY from_stn, to_stn)) * 100.0 / 
              AVG(duration) OVER (PARTITION BY from_stn, to_stn), 1) AS pct_deviation
    FROM trains
    WHERE duration > 0
)
SELECT 
    train_no,
    train_name,
    CONCAT(from_stn, ' -> ', to_stn) AS route,
    duration AS duration_mins,
    corridor_avg_duration,
    variance_mins,
    CONCAT('+', pct_deviation, '%') AS pct_deviation_from_avg
FROM corridor_stats
WHERE from_stn = 'BRC' AND to_stn IN ('ADI', 'MMCT', 'RTM')
ORDER BY variance_mins DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- QUERY 5: DEPARTURE VOLUME WEIGHTED BY WEEKLY OPERATIONAL FREQUENCY
-- Business Question: When are corridor departures concentrated across the day,
-- properly weighting weekly/periodic services by actual runs per week?
-- Note: Evening volumes on BRC-MMCT reflect the IRI 5-page (15:30) export cutoff.
-- Advanced Techniques: String manipulation for active day counting, Running Total Window
-- ---------------------------------------------------------------------
WITH weighted_hourly AS (
    SELECT 
        CAST(SUBSTRING_INDEX(dep_time, ':', 1) AS UNSIGNED) AS dep_hour,
        COUNT(*) AS scheduled_trains_in_slot,
        SUM(LENGTH(REPLACE(days, '.', ''))) AS weekly_departures_in_slot
    FROM trains
    WHERE dep_time IS NOT NULL AND dep_time != ''
    GROUP BY CAST(SUBSTRING_INDEX(dep_time, ':', 1) AS UNSIGNED)
)
SELECT 
    CONCAT(LPAD(dep_hour, 2, '0'), ':00 - ', LPAD(dep_hour, 2, '0'), ':59') AS time_window,
    scheduled_trains_in_slot,
    weekly_departures_in_slot,
    SUM(weekly_departures_in_slot) OVER (
        ORDER BY dep_hour 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_weekly_departures,
    CONCAT(
        ROUND(SUM(weekly_departures_in_slot) OVER (
            ORDER BY dep_hour 
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) * 100.0 / SUM(weekly_departures_in_slot) OVER (), 1),
        '%'
    ) AS cumulative_weekly_traffic_pct
FROM weighted_hourly
ORDER BY dep_hour ASC;
