# Indian Railways Timetable Analytics & Automated ETL Pipeline

[![Python](https://img.shields.io/badge/Python-3.10+-3776AB?style=flat&logo=python&logoColor=white)](https://www.python.org/)
[![MySQL](https://img.shields.io/badge/MySQL-8.0+-4479A1?style=flat&logo=mysql&logoColor=white)](https://www.mysql.com/)
[![Pandas](https://img.shields.io/badge/Pandas-2.0+-150458?style=flat&logo=pandas&logoColor=white)](https://pandas.pydata.org/)
[![Power BI](https://img.shields.io/badge/Power_BI-Ready-F2C811?style=flat&logo=powerbi&logoColor=black)](https://powerbi.microsoft.com/)

An end-to-end data analytics project engineering an automated extraction, cleaning, and quality assurance pipeline from semi-structured India Rail Info (IRI) PDF timetables into a normalized MySQL relational database, ready for advanced SQL analytics and interactive Power BI visualization.

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
                                                                      | - Power BI BI Model |
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

### 1.3 Data Quality & Reconciliation Audit Table
To guarantee complete data integrity before database loading, every parsed file was audited against the raw document row counts.

| PDF Source | Corridor / Route | PDF Pages | Printed Table Rows | Expected Train Records | Extracted & Loaded | Dropped / Orphan Rows | Data Integrity Status |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| `IRI-BRC-to-ADI.pdf` | Vadodara $\rightarrow$ Ahmedabad | 5 | 241 | 118 | 118 | 0 | 100% Reconciled |
| `IRI-BRC-to-MMCT.pdf` | Vadodara $\rightarrow$ Mumbai Central | 5 | 241 | 118 | 118 | 0 | 100% Reconciled |
| `IRI-BRC-to-RTM.pdf` | Vadodara $\rightarrow$ Ratlam | 5 | 241 | 118 | 118 | 0 | 100% Reconciled |
| `IRI-BRC-to-EKNR.pdf` | Vadodara $\rightarrow$ Ekta Nagar | 1 | 21 | 10 | 10 | 0 | 100% Reconciled |
| **Total** | **4 Core Corridors** | **16** | **744** | **364** | **364** | **0** | **100% Match (Zero Loss)** |

> **Audit Note:** The IRI portal returns a maximum of 5 pages (118 trains) for high-density trunk routes and 1 page (10 trains) for branch corridors. All 744 raw table rows across 16 pages were processed with **zero orphaned rows** and **zero data dropouts**.

---

### 1.4 Schema Transformation (Before vs. After)

| Field | Raw Extracted String | Cleaned MySQL Field | SQL Data Type | Purpose & Transformation |
| :--- | :--- | :--- | :--- | :--- |
| `TrainNo` | `"19417"` | `train_no` | `VARCHAR(10)` | Standardized unique service identifier |
| `Name` | `"Borivali - Vatva Exp\n"` | `train_name` | `VARCHAR(120)` | Stripped internal whitespace & newline characters |
| `Duration` | `"2h 4m"` | `duration` | `INT` | Converted text to **124** minutes for mathematical aggregation |
| `Distance` | `"92 km"` | `distance_km` | `INT` | Extracted numerical digits (92) for speed calculations |
| `Halts` | `"3"` | `halts` | `INT` | Numeric integer for delay penalty modeling |
| `Days` | Visual font colors | `days` | `VARCHAR(10)` | Extracted operational mask (e.g. `SFSMTWT`) via color coordinates |

---

## Repository Structure

```text
├── data/
│   ├── raw_pdfs/            # Original PDF timetable schedules (16 pages across 4 routes)
│   └── all_trains.csv       # Clean, normalized dataset (364 records)
├── scripts/
│   └── extract_trains.py    # Automated PDF ingestion, regex cleaning & MySQL ETL script
├── .gitignore               # Ignored environments, cache, and scratch files
└── README.md                # Project documentation and data quality audit
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

The script will automatically parse all PDFs in `data/raw_pdfs/`, export `data/all_trains.csv`, ensure the MySQL schema types are enforced, and populate the `trains` table with 364 verified records.

---

## Project Roadmap
- [x] **Section 1: Data Pipeline & Quality Assurance (ETL)** — PDF parsing, color-coded days extraction, duration normalization, 100% reconciliation audit.
- [ ] **Section 2: Advanced SQL Analytics** — Window functions (`LAG`, `LEAD`, `DENSE_RANK`), CTEs, service headway analysis, and halt penalty modeling.
- [ ] **Section 3: Interactive Power BI Dashboard** — Executive overview, speed distribution by train type, and departure density heatmaps.
