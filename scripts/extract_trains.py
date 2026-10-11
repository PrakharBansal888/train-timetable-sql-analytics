import pdfplumber, pandas as pd, glob, os

# Column names for the train-data rows (row 1 of each pair)
TRAIN_COLS = [
    "TrainNo", "Name", "Type", "_3", "_4",
    "From", "_6", "PF_From", "_8", "Dep", "_10", "_11",
    "To", "PF_To", "Arr", "_15", "Duration", "_17", "_18", "_19", "_20",
    "Halts", "_22", "_23", "Distance", "_25", "_26", "_27"
]

# Column names for the schedule rows (row 2 of each pair)
SCHED_COLS = [
    "_0", "_1", "_2", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "_9", "Sat",
    "_11", "_12", "_13", "_14", "_15", "_16", "_17", "_18",
    "Class_1", "_20", "Class_2", "_22", "Class_3", "_24", "Class_4", "_26", "_27"
]

def is_active_day_color(color):
    if color is None:
        return False
    # If RGB tuple, dark color (< 0.5) means active running day
    if isinstance(color, (tuple, list)):
        return color[0] < 0.5
    return False

frames = []
pdf_files = sorted(glob.glob("data/raw_pdfs/*.pdf") or glob.glob("*.pdf"))
for f in pdf_files:
    with pdfplumber.open(f) as pdf:
        for page in pdf.pages:
            # Pre-filter all day characters on this page (x between 225 and 335)
            page_day_chars = [
                c for c in page.chars
                if 220 <= c.get("x0", 0) <= 340 and c.get("text") in ["S", "M", "T", "W", "F"]
            ]

            # Find bounding boxes for each row in the table
            for table in page.extract_tables():
                rows = table[1:]  # skip header row
                i = 0
                while i < len(rows) - 1:
                    train_row = rows[i]
                    sched_row = rows[i + 1]

                    if train_row[0] and (not sched_row[0] or sched_row[0].strip() == ""):
                        td = dict(zip(TRAIN_COLS, train_row))
                        sd = dict(zip(SCHED_COLS, sched_row))
                        tr_no = str(td["TrainNo"]).strip()

                        # Locate train number on page to find its vertical position
                        # and match the active day characters
                        tr_words = [w for w in page.extract_words() if w["text"] == tr_no]
                        days = ""
                        if tr_words:
                            tr_top = tr_words[0]["top"]
                            matched_chars = [
                                c for c in page_day_chars
                                if tr_top <= c["top"] <= tr_top + 25
                            ]
                            matched_chars.sort(key=lambda x: x["x0"])
                            if len(matched_chars) >= 7:
                                # First 7 letters are S, M, T, W, T, F, S
                                days = "".join([
                                    c["text"] if is_active_day_color(c.get("non_stroking_color")) else "."
                                    for c in matched_chars[:7]
                                ])

                        # Fallback if text position matching fails
                        if not days or len(days) < 7:
                            days = "SMTWTFS"

                        # Collect non-empty classes
                        classes = []
                        for cls_col in ["Class_1", "Class_2", "Class_3", "Class_4"]:
                            val = sd.get(cls_col, "")
                            if val and val.strip():
                                classes.append(val.strip())

                        record = {
                            "TrainNo": td["TrainNo"],
                            "Name": (td["Name"] or "").replace("\n", " "),
                            "Type": td["Type"],
                            "From": td["From"],
                            "PF_From": td["PF_From"],
                            "Dep": td["Dep"],
                            "To": td["To"],
                            "PF_To": td["PF_To"],
                            "Arr": td["Arr"],
                            "Duration": td["Duration"],
                            "Halts": td["Halts"],
                            "Distance": td["Distance"],
                            "Days": days,
                            "Classes": ", ".join(classes),
                            "source_file": os.path.basename(f),
                        }
                        frames.append(record)
                        i += 2  # skip both rows
                    else:
                        i += 1  # orphan row, skip

df = pd.DataFrame(frames)

# Convert Duration (e.g. '2h 4m') to total numerical minutes (e.g. 124)
dur_h = df["Duration"].astype(str).str.extract(r"(\d+)\s*h")[0].fillna(0).astype(int)
dur_m = df["Duration"].astype(str).str.extract(r"(\d+)\s*m")[0].fillna(0).astype(int)
df["Duration"] = (dur_h * 60 + dur_m).astype("Int64")

df.to_csv("all_trains.csv", index=False)
if os.path.exists("data"):
    df.to_csv("data/all_trains.csv", index=False)

pd.set_option("display.max_columns", None)
pd.set_option("display.width", 200)
print(f"Extracted {len(df)} trains from {df['source_file'].nunique()} files")
print(f"Columns: {list(df.columns)}")
print(df.head(10).to_string(index=False))

# --- Database Insertion (Option 2a) ---
# Prepare column names matching the SQL schema:
sql_df = df.rename(columns={
    "TrainNo": "train_no",
    "Name": "train_name",
    "Type": "train_type",
    "From": "from_stn",
    "PF_From": "pf_from",
    "Dep": "dep_time",
    "To": "to_stn",
    "PF_To": "pf_to",
    "Arr": "arr_time",
    "Duration": "duration",
    "Halts": "halts",
    "Distance": "distance_km",
    "Days": "days",
    "Classes": "classes",
    "source_file": "source_file"
}).copy()

# Clean distance (e.g. '96 km' -> 96) and halts to numeric
sql_df["distance_km"] = sql_df["distance_km"].astype(str).str.extract(r"(\d+)").astype("Int64")
sql_df["halts"] = pd.to_numeric(sql_df["halts"], errors="coerce").astype("Int64")

from sqlalchemy import create_engine, text

# --- SET YOUR MYSQL CREDENTIALS HERE ---
MYSQL_USER = os.getenv("MYSQL_USER", "root")
MYSQL_PASSWORD = os.getenv("MYSQL_PASSWORD", "12345678")
MYSQL_HOST = os.getenv("MYSQL_HOST", "localhost")
MYSQL_PORT = os.getenv("MYSQL_PORT", "3306")
MYSQL_DB = os.getenv("MYSQL_DB", "trains_db")

connection_url = f"mysql+pymysql://{MYSQL_USER}:{MYSQL_PASSWORD}@{MYSQL_HOST}:{MYSQL_PORT}/{MYSQL_DB}"
engine = create_engine(connection_url)

print("\nRefreshing data in MySQL table 'trains'...")
with engine.connect() as conn:
    conn.execute(text("TRUNCATE TABLE trains;"))
    try:
        conn.execute(text("ALTER TABLE trains MODIFY COLUMN duration INT;"))
    except Exception:
        pass
    conn.commit()

sql_df.to_sql("trains", engine, if_exists="append", index=False)
print("Data refreshed successfully in MySQL with accurate days of operation!")
