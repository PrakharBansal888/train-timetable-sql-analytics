-- =====================================================================
-- INDIAN RAILWAYS ADVANCED CORRIDOR ANALYTICS
-- Database: trains_db | Table: trains (364 records across 4 corridors)
-- =====================================================================

USE trains_db;

-- ---------------------------------------------------------------------
-- QUERY 1: DEPARTURE HEADWAYS & CORRIDOR SERVICE DROUGHT ANALYSIS
-- Business Question: What is the headway (time gap between consecutive
-- departures) on high-density routes, and where are the longest service gaps?
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
        WHEN headway_minutes >= 120 THEN 'Severe Drought (>= 2h)'
        WHEN headway_minutes >= 60 THEN 'Moderate Gap (1h - 2h)'
        ELSE 'High-Frequency (< 1h)'
    END AS service_frequency_band
FROM headway_metrics
ORDER BY headway_minutes DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- QUERY 2: SPEED EFFICIENCY & CATEGORY BENCHMARKING
-- Business Question: Which train categories (Vande Bharat, Rajdhani,
-- Superfast, Express) achieve the highest average speed, and how do they rank?
-- Advanced Techniques: Multi-level CTE, DENSE_RANK() Window Function
-- ---------------------------------------------------------------------
WITH train_speeds AS (
    SELECT 
        train_no,
        train_name,
        COALESCE(NULLIF(train_type, ''), 'Standard') AS train_type,
        source_file,
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
-- QUERY 3: INTERMEDIATE HALT DELAY PENALTY MODEL
-- Business Question: How much travel time does each additional intermediate
-- halt add to a journey compared to the fastest benchmark train per corridor?
-- Advanced Techniques: Window MIN() partition, Chained CTE, Ratio modeling
-- ---------------------------------------------------------------------
WITH corridor_benchmarks AS (
    SELECT 
        source_file,
        MIN(duration) AS min_duration_mins
    FROM trains
    WHERE duration > 0
    GROUP BY source_file
),
halt_penalty_data AS (
    SELECT 
        t.train_no,
        t.train_name,
        t.train_type,
        t.source_file,
        t.halts,
        t.duration,
        b.min_duration_mins,
        (t.duration - b.min_duration_mins) AS delay_over_fastest,
        ROUND((t.duration - b.min_duration_mins) / NULLIF(t.halts, 0), 1) AS penalty_per_halt
    FROM trains t
    JOIN corridor_benchmarks b ON t.source_file = b.source_file
    WHERE t.halts > 0
)
SELECT 
    CASE 
        WHEN source_file LIKE '%ADI%' THEN 'Vadodara - Ahmedabad'
        WHEN source_file LIKE '%MMCT%' THEN 'Vadodara - Mumbai Central'
        WHEN source_file LIKE '%RTM%' THEN 'Vadodara - Ratlam'
        WHEN source_file LIKE '%EKNR%' THEN 'Vadodara - Ekta Nagar'
    END AS corridor,
    COUNT(*) AS analyzed_trains,
    ROUND(AVG(halts), 1) AS avg_halts,
    ROUND(AVG(delay_over_fastest), 1) AS avg_corridor_delay_mins,
    ROUND(AVG(penalty_per_halt), 1) AS avg_penalty_per_halt_mins
FROM halt_penalty_data
GROUP BY source_file
ORDER BY avg_penalty_per_halt_mins DESC;


-- ---------------------------------------------------------------------
-- QUERY 4: DURATION VARIANCE & ROUTE OUTLIER DETECTION
-- Business Question: Which trains deviate most severely from the corridor
-- average duration, identifying operational bottlenecks?
-- Advanced Techniques: AVG() OVER (PARTITION BY ...), Deviation %, Chained CTE
-- ---------------------------------------------------------------------
WITH corridor_stats AS (
    SELECT 
        train_no,
        train_name,
        train_type,
        from_stn,
        to_stn,
        duration,
        distance_km,
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
    CONCAT(pct_deviation, '%') AS pct_deviation_from_avg
FROM corridor_stats
WHERE from_stn = 'BRC' AND to_stn IN ('ADI', 'MMCT', 'RTM')
ORDER BY variance_mins DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- QUERY 5: CUMULATIVE DEPARTURE CAPACITY & HOURLY LOAD DISTRIBUTION
-- Business Question: At what time of day does corridor departure load
-- accumulate, and where are the traffic concentration bottlenecks?
-- Advanced Techniques: Window Running Total (SUM OVER ROWS BETWEEN), Overall Ratio
-- ---------------------------------------------------------------------
WITH hourly_slots AS (
    SELECT 
        CAST(SUBSTRING_INDEX(dep_time, ':', 1) AS UNSIGNED) AS dep_hour,
        COUNT(*) AS departures_in_hour
    FROM trains
    WHERE dep_time IS NOT NULL AND dep_time != ''
    GROUP BY CAST(SUBSTRING_INDEX(dep_time, ':', 1) AS UNSIGNED)
)
SELECT 
    CONCAT(LPAD(dep_hour, 2, '0'), ':00 - ', LPAD(dep_hour, 2, '0'), ':59') AS time_window,
    departures_in_hour,
    SUM(departures_in_hour) OVER (
        ORDER BY dep_hour 
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total_departures,
    CONCAT(
        ROUND(SUM(departures_in_hour) OVER (
            ORDER BY dep_hour 
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) * 100.0 / SUM(departures_in_hour) OVER (), 1), 
        '%'
    ) AS cumulative_traffic_pct
FROM hourly_slots
ORDER BY dep_hour ASC;
