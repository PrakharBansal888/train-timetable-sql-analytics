# Indian Railways Timetable Analytics & Automated ETL Pipeline

[![Python](https://img.shields.io/badge/Python-3.10+-3776AB?style=flat&logo=python&logoColor=white)](https://www.python.org/)
[![MySQL](https://img.shields.io/badge/MySQL-8.0+-4479A1?style=flat&logo=mysql&logoColor=white)](https://www.mysql.com/)
[![Pandas](https://img.shields.io/badge/Pandas-2.0+-150458?style=flat&logo=pandas&logoColor=white)](https://pandas.pydata.org/)
[![Power BI](https://img.shields.io/badge/Power_BI-Ready-F2C811?style=flat&logo=powerbi&logoColor=black)](https://powerbi.microsoft.com/)

An end-to-end data analytics project engineering an automated extraction, cleaning, and quality assurance pipeline from semi-structured India Rail Info (IRI) PDF timetables into a normalized MySQL relational database, modeled for advanced SQL analytics and interactive Power BI visualization.

---

## Architecture Overview

```text
+-----------------------+       +-----------------------------+       +---------------------+
|   Raw PDF Timetables  |  ==>  | Python ETL Pipeline         |  ==>  | Clean Relational    |
| (Multi-line, Colors,  |       | - pdfplumber character OCR  |       | MySQL Database      |
|  Embedded Strings)    |       | - Luminance color detection |       | (Typed Schema, INT  |
|                       |       | - Row-pair synchronization  |       |  durations & dist)  |
+-----------------------+       +-----------------------------+       +---------------------+
                                                                                 ||
                                                                                 \/
                                                                      +---------------------+
                                                                      | Downstream Analysis |
                                                                      | - Advanced SQL CTEs |
                                                                      | - v_trains_clean    |
                                                                      | - Power BI Model    |
                                                                      +---------------------+
```

---

## 1. Data Pipeline & Quality Assurance (ETL)

### 1.1 The Ingestion Challenge
Extracting timetable data directly from operational railway PDFs involves several real-world data traps:
1. **Two-Row Interleaved Records:** Each scheduled train does not occupy a single continuous row. Instead, every record is split across **two interleaved table rows**:
   - *Row 1 (Metadata):* Train Number, Train Name, Category, Origin, Destination, Departure Time, Arrival Time, Duration, Halts, Distance.
   - *Row 2 (Schedule):* Weekly operational days (`S M T W T F S`) and Coach Classes (`1A, 2A, 3A, SL`).
2. **Visual Color-Encoding (The "Active Days" Trap):** The day letters `S M T W T F S` are statically printed across all schedule rows. Whether a train actually runs on that day is indicated purely by **font color** (dark black/navy for active days vs. light grey/faded for non-operational days). Standard PDF text extractors extract all letters identically, falsely reporting all trains as daily services.
3. **Non-Numeric Measurement Strings:** Core quantitative variables were formatted as unstructured text (e.g., Duration as `"2h 4m"` and Distance as `"92 km"`), preventing relational calculations, mathematical sorting, and aggregations.

---

### 1.2 Pipeline Architecture & Cleaning Logic
The automated ingestion script (`scripts/extract_trains.py`) resolves these challenges systematically:

- **Row-Pair Synchronization:** Iterates through tables in steps of 2, validating that Row 1 contains a non-null Train Number and Row 2 matches the schedule schema.
- **Character-Level RGB Luminance Filtering:** Uses `pdfplumber.chars` to extract raw bounding boxes and non-stroking colors within the timetable days column ($x \in [220, 340]$). Characters with RGB channel values $< 0.5$ are mapped to active operating days, and non-operational days are encoded as `.` (e.g., `S.M.W.F.`).
- **Mathematical Duration Standardization:** Regular expressions parse hours (`(\d+)h`) and minutes (`(\d+)m`) from string values, converting travel time into pure integer minutes:
  $$\text{duration\_minutes} = (\text{hours} \times 60) + \text{minutes}$$
- **Integer Distance Extraction:** Strips non-numeric unit suffixes (`" km"`) to produce a clean integer `distance_km` column.

---

### 1.3 Data Scope, Export Truncation & Reconciliation Audit
To maintain complete data honesty, the extracted records are reconciled against both the document headers and printed rows:

| PDF Source | Corridor / Route | Portal Header Count | Printed PDF Rows | Extracted & Loaded | Departure Window Captured | Parsing Match |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| `IRI-BRC-to-ADI.pdf` | Vadodara $\rightarrow$ Ahmedabad | 151 | 118 | 118 | 00:41 – 20:44 | 100% of printed |
| `IRI-BRC-to-MMCT.pdf` | Vadodara $\rightarrow$ Mumbai Central | 167 | 118 | 118 | 00:06 – 15:30 | 100% of printed |
| `IRI-BRC-to-RTM.pdf` | Vadodara $\rightarrow$ Ratlam | 129 | 118 | 118 | 00:18 – 22:56 | 100% of printed |
| `IRI-BRC-to-EKNR.pdf` | Vadodara $\rightarrow$ Ekta Nagar | 10 | 10 | 10 | 05:25 – 18:45 | 100% of printed |
| **Total** | **4 Core Corridors** | **457** | **364** | **364** | **Combined** | **100% Zero-Loss** |

> **Critical Data Limitation Note:**
> The India Rail Info portal hard-caps printable outputs at 5 pages (118 trains) for dense trunk routes. Consequently, the dataset captures the **first 118 departures sorted chronologically**. 
> - For **Vadodara $\rightarrow$ Mumbai Central**, the cutoff occurs at **15:30**, omitting ~49 evening/night departures (~29% of the route).
> - For **Vadodara $\rightarrow$ Ahmedabad**, the cutoff occurs at **20:44**, omitting ~33 late-night services.
> - Downstream time-of-day queries and visual distributions are strictly scoped to the observed daytime operational window to avoid survivorship bias.

---

### 1.4 Schema Transformation (Before vs. After)

| Field | Raw Extracted String | Cleaned MySQL Field | SQL Data Type | Purpose & Transformation |
| :--- | :--- | :--- | :--- | :--- |
| `TrainNo` | `"19417"` | `train_no` | `VARCHAR(10)` | Standardized unique service identifier |
| `Name` | `"Borivali - Vatva Exp\n"` | `train_name` | `VARCHAR(120)` | Stripped internal whitespace & newline characters |
| `Duration` | `"2h 4m"` | `duration` | `INT` | Converted text to **124** minutes for mathematical aggregation |
| `Distance` | `"92 km"` | `distance_km` | `INT` | Extracted numerical digits (92) for speed calculations |
| `Halts` | `"3"` | `halts` | `INT` | Numeric integer for delay penalty regression modeling |
| `Days` | Visual font colors | `days` | `VARCHAR(10)` | Extracted operational mask (e.g. `SFSMTWT`) via color coordinates |

---

## 2. Advanced SQL Analytics (CTEs, Window Functions & Corridor Insights)

The complete SQL scripts are located in [`queries/advanced_analytics.sql`](queries/advanced_analytics.sql).

### Query 1: Departure Headways (Observed 00:41 – 20:44 Window on BRC $\rightarrow$ ADI)
- **Business Question:** What is the headway (time interval between consecutive departures) on the Vadodara $\rightarrow$ Ahmedabad mainline within the observed operational window?
- **Advanced SQL Techniques:** `LAG() OVER (PARTITION BY ... ORDER BY ...)`, `STR_TO_DATE()`, `TIMESTAMPDIFF()`, Common Table Expressions (CTE).

```sql
WITH departures_ranked AS (
    SELECT 
        train_no, train_name, train_type, from_stn, to_stn, dep_time,
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
        train_no, train_name, train_type, from_stn, to_stn, dep_time,
        TIMESTAMPDIFF(MINUTE, prev_dep_dt, dep_dt) AS headway_minutes
    FROM departures_ranked
    WHERE prev_dep_dt IS NOT NULL
)
SELECT 
    train_no, train_name, train_type, dep_time, headway_minutes,
    CASE 
        WHEN headway_minutes >= 120 THEN 'Gap >= 2 Hours'
        WHEN headway_minutes >= 60 THEN 'Gap 1 - 2 Hours'
        ELSE 'Frequent (< 1 Hour)'
    END AS headway_band
FROM headway_metrics
ORDER BY headway_minutes DESC
LIMIT 5;
```

**Output:**

| train_no | train_name | train_type | dep_time | headway_minutes | headway_band |
| :--- | :--- | :---: | :---: | :---: | :--- |
| `12656` | Navjeevan SF Exp | SF | 15:32 | **187** | Gap >= 2 Hours |
| `20823` | Puri - Ajmer SF Exp | SF | 07:47 | **95** | Gap 1 - 2 Hours |
| `12834` | Howrah - Ahmedabad SF Exp | SF | 09:39 | **67** | Gap 1 - 2 Hours |
| `22953` | Gujarat SF Exp | SF | 12:25 | **48** | Frequent (< 1 Hour) |
| `20901` | Gandhinagar Vande Bharat | VB | 10:26 | **38** | Frequent (< 1 Hour) |

> **Key Finding:** Within the observed 00:41–20:44 timetable window, the single largest service gap is **187 minutes (3h 7m)** between the Gujarat SF Exp (12:25) and Navjeevan SF Exp (15:32), marking the only multi-hour afternoon drought on an otherwise high-frequency corridor.

---

### Query 2: Speed Efficiency & Rank by Train Category (Sample Filter: $N \ge 3$)
- **Business Question:** How do train categories rank by average commercial speed, filtering out single-service outliers ($N \ge 3$)?
- **Advanced SQL Techniques:** Chained CTEs, `DENSE_RANK() OVER (ORDER BY avg_speed DESC)`, `HAVING COUNT(*) >= 3`.

```sql
WITH train_speeds AS (
    SELECT 
        train_no, train_name,
        COALESCE(NULLIF(train_type, ''), 'Standard') AS train_type,
        distance_km, duration,
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
    train_type, service_count, avg_speed_kmh, min_speed_kmh, max_speed_kmh,
    DENSE_RANK() OVER (ORDER BY avg_speed_kmh DESC) AS speed_rank
FROM category_summary
ORDER BY speed_rank ASC
LIMIT 5;
```

**Output:**

| train_type | service_count | avg_speed_kmh | min_speed_kmh | max_speed_kmh | speed_rank |
| :---: | :---: | :---: | :---: | :---: | :---: |
| **VB** (Vande Bharat) | 4 | **80.1** | 58.9 | 92.3 | **1** |
| **Raj** (Rajdhani) | 4 | **79.2** | 72.3 | 82.9 | **2** |
| **Drnt** (Duronto) | 9 | **75.2** | 69.6 | 78.3 | **3** |
| **GR** (Garib Rath) | 4 | **69.9** | 54.5 | 77.9 | **4** |
| **SKr** (Sampark Kranti) | 9 | **67.1** | 42.7 | 78.7 | **5** |

> **Key Finding:** Premium services consistently top commercial speed rankings: **Vande Bharat** averages **80.1 km/h** (+44.8% vs. standard Express at 55.3 km/h), followed closely by **Rajdhani** at **79.2 km/h** (+43.2%) and **Duronto** at **75.2 km/h** (+36.0%). Standard Express (`Exp`, $n=101$) averages 55.3 km/h, while local `MEMU` services ($n=6$) average 43.5 km/h.

---

### Query 3: Empirical Halt Penalty Model (Ordinary Least Squares Linear Regression)
- **Business Question:** What is the empirical marginal time cost (minutes added per additional halt) within comparable train categories (Superfast & Express)?
- **Statistical Model:** OLS slope coefficient $\beta_1 = \frac{\text{Cov}(\text{Halts}, \text{Duration})}{\text{Var}(\text{Halts})} = \frac{\overline{XY} - \bar{X}\bar{Y}}{\overline{X^2} - (\bar{X})^2}$ computed directly via SQL aggregation functions.

```sql
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
```

**Output:**

| Corridor | Sample Size (SF & Exp) | Avg Halts | Avg Duration | Regression Slope ($\beta_1$) |
| :--- | :---: | :---: | :---: | :---: |
| **Vadodara $\rightarrow$ Mumbai Central** | 84 | 5.3 | 372.2 mins | **+7.6 mins / halt** |
| **Vadodara $\rightarrow$ Ratlam** | 91 | 1.6 | 236.2 mins | **+4.2 mins / halt** |
| **Vadodara $\rightarrow$ Ahmedabad** | 93 | 1.9 | 124.1 mins | **+1.4 mins / halt** |
| **Vadodara $\rightarrow$ Ekta Nagar** | 5 | 0.0 | 107.8 mins | *Null (zero halt variance)* |

> **Key Finding:** Isolating comparable Superfast and Express trains reveals realistic empirical halt penalties: an additional halt adds an estimated **7.6 minutes** to transit time on the Mumbai trunk line, **4.2 minutes** on the Ratlam line, and **1.4 minutes** on the short Ahmedabad corridor.

---

### Query 4: Route Duration Outlier Detection (Empirical Variance)
- **Business Question:** Which specific train services show the largest duration deviation from their corridor's average transit duration?
- **Advanced SQL Techniques:** `AVG() OVER (PARTITION BY ...)` Window Function, Variance Calculation, Percentage Deviation Modeling.

```sql
WITH corridor_stats AS (
    SELECT 
        train_no, train_name, train_type, from_stn, to_stn, duration,
        ROUND(AVG(duration) OVER (PARTITION BY from_stn, to_stn), 1) AS corridor_avg_duration,
        ROUND(duration - AVG(duration) OVER (PARTITION BY from_stn, to_stn), 1) AS variance_mins,
        ROUND((duration - AVG(duration) OVER (PARTITION BY from_stn, to_stn)) * 100.0 / 
              AVG(duration) OVER (PARTITION BY from_stn, to_stn), 1) AS pct_deviation
    FROM trains
    WHERE duration > 0
)
SELECT 
    train_no, train_name,
    CONCAT(from_stn, ' -> ', to_stn) AS route,
    duration AS duration_mins, corridor_avg_duration, variance_mins,
    CONCAT('+', pct_deviation, '%') AS pct_deviation_from_avg
FROM corridor_stats
WHERE from_stn = 'BRC' AND to_stn IN ('ADI', 'MMCT', 'RTM')
ORDER BY variance_mins DESC
LIMIT 5;
```

**Output:**

| train_no | train_name | route | duration_mins | corridor_avg_duration | variance_mins | pct_deviation_from_avg |
| :---: | :--- | :---: | :---: | :---: | :---: | :---: |
| `19819` | Vadodara - Kota Exp | BRC $\rightarrow$ RTM | 395 | 233.0 | **+162.0 mins** | **+69.5%** |
| `09186` | Kanpur - Mumbai Central SF Spl | BRC $\rightarrow$ MMCT | 460 | 359.2 | **+100.8 mins** | **+28.1%** |
| `19626` | Bandra - Daurai Weekly Exp | BRC $\rightarrow$ RTM | 317 | 233.0 | **+84.0 mins** | **+36.0%** |
| `22954` | Gujarat SF Exp | BRC $\rightarrow$ MMCT | 440 | 359.2 | **+80.8 mins** | **+22.5%** |
| `19019` | Bandra - Haridwar Exp | BRC $\rightarrow$ RTM | 307 | 233.0 | **+74.0 mins** | **+31.7%** |

> **Key Finding:** Train `19819` (Vadodara - Kota Exp) exhibits the single largest duration variance across all examined corridors, taking **395 minutes (6h 35m)** compared to the 233.0-minute route average (**+162.0 minutes / +69.5% slower**).

---

### Query 5: Departure Volume Weighted by Weekly Operational Frequency
- **Business Question:** When are corridor departures concentrated across the day, properly weighting weekly/periodic services by actual runs per week?
- **Data Reality Addressed:** In the raw timetable, only 58 of 364 trains run daily; 306 are periodic or weekly services. Treating every record as a daily departure artificially inflates weekly capacity by up to $7\times$. Furthermore, afternoon/evening volumes on BRC-MMCT reflect the IRI 15:30 export truncation.
- **Advanced Techniques:** String length replacement for active operational days (`LENGTH(REPLACE(days, '.', ''))`), Running Total Window Function (`SUM() OVER (...)`).

```sql
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
```

**Output:**

| Time Window | Scheduled Train Records | Weekly Departures in Slot | Running Weekly Departures | Cumulative Weekly Traffic % |
| :---: | :---: | :---: | :---: | :---: |
| `00:00 - 00:59` | 16 | 82 | 82 | 7.3% |
| `01:00 - 01:59` | 28 | 73 | 155 | 13.9% |
| `03:00 - 03:59` | 23 | 62 | 272 | 24.4% |
| `05:00 - 05:59` | 29 | 100 | 441 | 39.5% |
| `09:00 - 09:59` | 30 | 109 | 667 | 59.8% |
| `10:00 - 10:59` | 29 | 102 | 769 | 68.9% |
| `12:00 - 13:59` | 4 | 20 | 817 | 73.2% |

> **Key Finding:** Across all 364 scheduled services, there are **1,116 total departures per week** (406 daily, 710 periodic). Morning traffic peaks heavily at 09:00–10:59 (211 weekly departures). Note that departure volume drops off sharply after 15:00 primarily due to the 5-page cutoff on the high-density Mumbai corridor.

---

## Repository Structure

```text
├── data/
│   ├── raw_pdfs/              # Original PDF timetable schedules (16 pages across 4 routes)
│   └── all_trains.csv         # Clean, normalized dataset (364 records)
├── queries/
│   ├── advanced_analytics.sql # Advanced SQL queries (CTEs, Window Functions, OLS Regression)
│   └── v_trains_clean.sql     # Dimensional database view pre-configured for Power BI
├── scripts/
│   └── extract_trains.py      # Automated PDF ingestion, regex cleaning & MySQL ETL script
├── .gitignore                 # Ignored environments, cache, and scratch files
└── README.md                  # Project documentation, data quality audit & SQL showcase
```

---

## Quickstart & Reproducibility

### 1. Prerequisites
- Python 3.10+
- MySQL 8.0+

### 2. Environment Setup
```bash
pip install pdfplumber pandas sqlalchemy pymysql
```

### 3. Run the Pipeline
```bash
# Set credentials (or use default root/12345678)
export MYSQL_USER="root"
export MYSQL_PASSWORD="your_password"
export MYSQL_DB="trains_db"

python scripts/extract_trains.py
```

### 4. Create the Power BI View & Run Analytical Queries
```bash
mysql -u root -p trains_db < queries/v_trains_clean.sql
mysql -u root -p trains_db < queries/advanced_analytics.sql
```

---

## Project Roadmap
- [x] **Section 1: Data Pipeline & Quality Assurance (ETL)** — PDF parsing, color-coded days extraction, duration normalization, honest truncation documentation.
- [x] **Section 2: Advanced SQL Analytics** — Window functions (`LAG`, `DENSE_RANK`, `RUNNING TOTAL`), Chained CTEs, OLS regression slope for halt penalty, duration variance, and weekly-weighted traffic distribution.
- [ ] **Section 3: Interactive Power BI Dashboard** — Executive overview, speed distribution by train type, and departure density heatmaps using `v_trains_clean`.
