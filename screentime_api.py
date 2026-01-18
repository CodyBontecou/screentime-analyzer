#!/usr/bin/env python3
"""
Screen Time API - FastAPI wrapper for Screen Time data extraction.

Supports two modes:
1. Local mode (macOS): Reads directly from knowledgeC.db
2. Server mode (Linux/cloud): Receives uploads and stores in local SQLite

Run with: uvicorn screentime_api:app --reload
"""

import os
import sqlite3

from dotenv import load_dotenv
load_dotenv()
from datetime import date, datetime, timedelta
from enum import Enum
from pathlib import Path
from typing import Annotated, Optional

from fastapi import Depends, FastAPI, HTTPException, Query, Security
from fastapi.responses import StreamingResponse
from fastapi.security import APIKeyHeader
from pydantic import BaseModel, Field

import csv
import io
import json

# Server-side storage path (for uploaded data)
DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
SERVER_DB_PATH = DATA_DIR / "screentime.db"

# Try to import local macOS functions (may not be available on Linux)
try:
    from screentime import (
        DEFAULT_DB_PATH,
        copy_database_to_temp,
        get_app_usage,
        aggregate_by_app,
        format_duration,
    )
    HAS_LOCAL_DB = True
except Exception:
    DEFAULT_DB_PATH = Path.home() / "Library/Application Support/Knowledge/knowledgeC.db"
    HAS_LOCAL_DB = False

    def format_duration(seconds: float) -> str:
        """Format duration in human-readable format."""
        if seconds is None or seconds < 0:
            return "0s"
        hours = int(seconds // 3600)
        minutes = int((seconds % 3600) // 60)
        secs = int(seconds % 60)
        parts = []
        if hours > 0:
            parts.append(f"{hours}h")
        if minutes > 0:
            parts.append(f"{minutes}m")
        if secs > 0 or not parts:
            parts.append(f"{secs}s")
        return " ".join(parts)

    def aggregate_by_app(usage_data: list[dict]) -> list[dict]:
        """Aggregate usage data by app, summing total duration."""
        app_totals = {}
        for entry in usage_data:
            app = entry["app_name"]
            if app not in app_totals:
                app_totals[app] = 0
            app_totals[app] += entry["duration_seconds"]
        result = [
            {"app_name": app, "total_duration_seconds": duration}
            for app, duration in app_totals.items()
        ]
        result.sort(key=lambda x: x["total_duration_seconds"], reverse=True)
        return result

import shutil

# API Key configuration
API_KEY = os.environ.get("API_KEY")
api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


async def verify_api_key(api_key: str = Security(api_key_header)) -> str:
    """Verify the API key from request header."""
    if not API_KEY:
        raise HTTPException(
            status_code=500,
            detail="API_KEY environment variable not set. Server misconfigured.",
        )
    if not api_key:
        raise HTTPException(
            status_code=401,
            detail="Missing API key. Provide X-API-Key header.",
        )
    if api_key != API_KEY:
        raise HTTPException(
            status_code=403,
            detail="Invalid API key.",
        )
    return api_key


# Server-side database functions
def init_server_db():
    """Initialize the server-side SQLite database."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(SERVER_DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app_name TEXT NOT NULL,
            duration_seconds REAL NOT NULL,
            start_time TEXT,
            end_time TEXT,
            UNIQUE(app_name, start_time, end_time)
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_start_time ON usage(start_time)")
    conn.commit()
    conn.close()


def get_server_usage(
    start_date: Optional[datetime] = None,
    end_date: Optional[datetime] = None
) -> list[dict]:
    """Get usage data from server-side database."""
    if not SERVER_DB_PATH.exists():
        return []

    conn = sqlite3.connect(SERVER_DB_PATH)
    conn.row_factory = sqlite3.Row

    query = "SELECT app_name, duration_seconds, start_time, end_time FROM usage WHERE 1=1"
    params = []

    if start_date:
        query += " AND start_time >= ?"
        params.append(start_date.isoformat())

    if end_date:
        query += " AND end_time <= ?"
        params.append(end_date.isoformat())

    query += " ORDER BY start_time DESC"

    try:
        cursor = conn.execute(query, params)
        results = []
        for row in cursor:
            results.append({
                "app_name": row["app_name"],
                "duration_seconds": row["duration_seconds"],
                "start_time": datetime.fromisoformat(row["start_time"]) if row["start_time"] else None,
                "end_time": datetime.fromisoformat(row["end_time"]) if row["end_time"] else None,
            })
        return results
    finally:
        conn.close()


def insert_usage_records(records: list[dict]) -> int:
    """Insert usage records into server database. Returns count of new records."""
    init_server_db()
    conn = sqlite3.connect(SERVER_DB_PATH)

    inserted = 0
    for record in records:
        try:
            conn.execute(
                """INSERT OR IGNORE INTO usage (app_name, duration_seconds, start_time, end_time)
                   VALUES (?, ?, ?, ?)""",
                (
                    record["app_name"],
                    record["duration_seconds"],
                    record["start_time"],
                    record["end_time"],
                )
            )
            if conn.total_changes > inserted:
                inserted = conn.total_changes
        except sqlite3.IntegrityError:
            pass  # Duplicate record, skip

    conn.commit()
    conn.close()
    return inserted


app = FastAPI(
    title="Screen Time API",
    description="""
API for extracting and analyzing macOS Screen Time data from knowledgeC.db.

**Note:** Requires Full Disk Access permission on macOS to read the Screen Time database.
Grant access in System Preferences > Privacy & Security > Full Disk Access.
    """,
    version="1.0.0",
)


class OutputFormat(str, Enum):
    json = "json"
    csv = "csv"


class UsageRecord(BaseModel):
    app_name: str
    duration_seconds: float
    duration_formatted: str
    start_time: Optional[datetime]
    end_time: Optional[datetime]


class AppSummary(BaseModel):
    app_name: str
    total_duration_seconds: float
    total_duration_formatted: str


class DailyBreakdown(BaseModel):
    date: date
    total_duration_seconds: float
    total_duration_formatted: str
    apps: list[AppSummary]


class UsageResponse(BaseModel):
    record_count: int
    start_date: Optional[date]
    end_date: Optional[date]
    records: list[UsageRecord]


class SummaryResponse(BaseModel):
    total_duration_seconds: float
    total_duration_formatted: str
    start_date: Optional[date]
    end_date: Optional[date]
    app_count: int
    apps: list[AppSummary]


class DailyResponse(BaseModel):
    start_date: Optional[date]
    end_date: Optional[date]
    days: list[DailyBreakdown]


class HealthResponse(BaseModel):
    status: str
    database_exists: bool
    database_path: str
    server_db_exists: bool = False
    server_db_path: str = ""
    record_count: int = 0


class UploadRecord(BaseModel):
    app_name: str
    duration_seconds: float
    start_time: Optional[str] = None
    end_time: Optional[str] = None


class UploadRequest(BaseModel):
    records: list[UploadRecord]


class UploadResponse(BaseModel):
    status: str
    records_received: int
    records_inserted: int


def get_usage_data(start_date: Optional[date], end_date: Optional[date]) -> list[dict]:
    """Fetch usage data with proper error handling.

    Tries local macOS database first, falls back to server-side storage.
    """
    start_dt = datetime.combine(start_date, datetime.min.time()) if start_date else None
    end_dt = datetime.combine(end_date, datetime.max.time()) if end_date else None

    # Try local macOS database first (if available and on macOS)
    if HAS_LOCAL_DB and DEFAULT_DB_PATH.exists():
        temp_db = None
        try:
            temp_db = copy_database_to_temp(DEFAULT_DB_PATH)
            return get_app_usage(temp_db, start_dt, end_dt)
        except PermissionError:
            raise HTTPException(
                status_code=403,
                detail={
                    "error": "Permission denied",
                    "hint": "Grant Full Disk Access to the process running this API.",
                }
            )
        except Exception as e:
            # Fall through to try server database
            pass
        finally:
            if temp_db and temp_db.exists():
                shutil.rmtree(temp_db.parent, ignore_errors=True)

    # Fallback to server-side database (for cloud deployment)
    if SERVER_DB_PATH.exists():
        return get_server_usage(start_dt, end_dt)

    raise HTTPException(
        status_code=503,
        detail={
            "error": "No data available",
            "hint": "Either run on macOS with Screen Time enabled, or upload data using POST /upload",
        }
    )


@app.get("/health", response_model=HealthResponse, tags=["System"])
def health_check():
    """Check API health and database availability."""
    record_count = 0
    if SERVER_DB_PATH.exists():
        try:
            conn = sqlite3.connect(SERVER_DB_PATH)
            cursor = conn.execute("SELECT COUNT(*) FROM usage")
            record_count = cursor.fetchone()[0]
            conn.close()
        except Exception:
            pass

    return HealthResponse(
        status="ok",
        database_exists=DEFAULT_DB_PATH.exists(),
        database_path=str(DEFAULT_DB_PATH),
        server_db_exists=SERVER_DB_PATH.exists(),
        server_db_path=str(SERVER_DB_PATH),
        record_count=record_count,
    )


@app.post("/upload", response_model=UploadResponse, tags=["Upload"])
def upload_usage_data(
    request: UploadRequest,
    _: str = Depends(verify_api_key),
):
    """
    Upload Screen Time usage records to the server.

    Use this endpoint to sync data from your Mac to the cloud server.
    Duplicate records (same app, start_time, end_time) are automatically skipped.
    """
    records = [
        {
            "app_name": r.app_name,
            "duration_seconds": r.duration_seconds,
            "start_time": r.start_time,
            "end_time": r.end_time,
        }
        for r in request.records
    ]

    inserted = insert_usage_records(records)

    return UploadResponse(
        status="ok",
        records_received=len(records),
        records_inserted=inserted,
    )


@app.get("/usage", response_model=UsageResponse, tags=["Usage Data"])
def get_usage(
    _: str = Depends(verify_api_key),
    start_date: Optional[date] = Query(None, description="Filter from this date (inclusive)"),
    end_date: Optional[date] = Query(None, description="Filter until this date (inclusive)"),
    limit: Optional[int] = Query(None, ge=1, le=10000, description="Limit number of records returned"),
):
    """
    Get detailed app usage records.

    Returns individual usage sessions with app name, duration, and timestamps.
    """
    usage_data = get_usage_data(start_date, end_date)

    records = [
        UsageRecord(
            app_name=r["app_name"],
            duration_seconds=r["duration_seconds"],
            duration_formatted=format_duration(r["duration_seconds"]),
            start_time=r["start_time"],
            end_time=r["end_time"],
        )
        for r in usage_data
    ]

    if limit:
        records = records[:limit]

    return UsageResponse(
        record_count=len(records),
        start_date=start_date,
        end_date=end_date,
        records=records,
    )


@app.get("/summary", response_model=SummaryResponse, tags=["Usage Data"])
def get_summary(
    _: str = Depends(verify_api_key),
    start_date: Optional[date] = Query(None, description="Filter from this date (inclusive)"),
    end_date: Optional[date] = Query(None, description="Filter until this date (inclusive)"),
    top: Optional[int] = Query(None, ge=1, le=1000, description="Limit to top N apps by usage"),
):
    """
    Get aggregated usage summary by app.

    Returns total usage time per app, sorted by duration descending.
    """
    usage_data = get_usage_data(start_date, end_date)
    aggregated = aggregate_by_app(usage_data)

    if top:
        aggregated = aggregated[:top]

    total_seconds = sum(a["total_duration_seconds"] for a in aggregated)

    apps = [
        AppSummary(
            app_name=a["app_name"],
            total_duration_seconds=a["total_duration_seconds"],
            total_duration_formatted=format_duration(a["total_duration_seconds"]),
        )
        for a in aggregated
    ]

    return SummaryResponse(
        total_duration_seconds=total_seconds,
        total_duration_formatted=format_duration(total_seconds),
        start_date=start_date,
        end_date=end_date,
        app_count=len(apps),
        apps=apps,
    )


@app.get("/daily", response_model=DailyResponse, tags=["Usage Data"])
def get_daily_breakdown(
    _: str = Depends(verify_api_key),
    start_date: Optional[date] = Query(None, description="Filter from this date (inclusive)"),
    end_date: Optional[date] = Query(None, description="Filter until this date (inclusive)"),
    top_apps: int = Query(10, ge=1, le=100, description="Number of top apps per day"),
):
    """
    Get daily usage breakdown.

    Returns usage grouped by day with top apps for each day.
    """
    usage_data = get_usage_data(start_date, end_date)

    # Group by date
    daily_data: dict[date, dict[str, float]] = {}
    for entry in usage_data:
        if entry["start_time"]:
            date_key = entry["start_time"].date()
            if date_key not in daily_data:
                daily_data[date_key] = {}

            app = entry["app_name"]
            if app not in daily_data[date_key]:
                daily_data[date_key][app] = 0
            daily_data[date_key][app] += entry["duration_seconds"]

    # Build response
    days = []
    for day in sorted(daily_data.keys(), reverse=True):
        apps_dict = daily_data[day]
        sorted_apps = sorted(apps_dict.items(), key=lambda x: x[1], reverse=True)[:top_apps]
        total_seconds = sum(apps_dict.values())

        days.append(DailyBreakdown(
            date=day,
            total_duration_seconds=total_seconds,
            total_duration_formatted=format_duration(total_seconds),
            apps=[
                AppSummary(
                    app_name=app,
                    total_duration_seconds=duration,
                    total_duration_formatted=format_duration(duration),
                )
                for app, duration in sorted_apps
            ],
        ))

    return DailyResponse(
        start_date=start_date,
        end_date=end_date,
        days=days,
    )


@app.get("/export", tags=["Export"])
def export_data(
    _: str = Depends(verify_api_key),
    format: OutputFormat = Query(..., description="Export format"),
    start_date: Optional[date] = Query(None, description="Filter from this date (inclusive)"),
    end_date: Optional[date] = Query(None, description="Filter until this date (inclusive)"),
    summary: bool = Query(False, description="Export aggregated summary instead of detailed records"),
):
    """
    Export usage data as CSV or JSON file download.
    """
    usage_data = get_usage_data(start_date, end_date)

    if summary:
        data = aggregate_by_app(usage_data)
        filename = "screentime_summary"
    else:
        data = usage_data
        filename = "screentime_usage"

    if start_date:
        filename += f"_from_{start_date}"
    if end_date:
        filename += f"_to_{end_date}"

    if format == OutputFormat.csv:
        output = io.StringIO()

        if summary:
            writer = csv.DictWriter(output, fieldnames=["app_name", "total_duration_seconds", "total_duration_formatted"])
            writer.writeheader()
            for row in data:
                writer.writerow({
                    "app_name": row["app_name"],
                    "total_duration_seconds": row["total_duration_seconds"],
                    "total_duration_formatted": format_duration(row["total_duration_seconds"]),
                })
        else:
            writer = csv.DictWriter(output, fieldnames=["app_name", "duration_seconds", "start_time", "end_time"])
            writer.writeheader()
            for row in data:
                writer.writerow({
                    "app_name": row["app_name"],
                    "duration_seconds": row["duration_seconds"],
                    "start_time": row["start_time"].isoformat() if row["start_time"] else "",
                    "end_time": row["end_time"].isoformat() if row["end_time"] else "",
                })

        output.seek(0)
        return StreamingResponse(
            iter([output.getvalue()]),
            media_type="text/csv",
            headers={"Content-Disposition": f"attachment; filename={filename}.csv"},
        )

    else:  # JSON
        if summary:
            output_data = [
                {
                    "app_name": row["app_name"],
                    "total_duration_seconds": row["total_duration_seconds"],
                    "total_duration_formatted": format_duration(row["total_duration_seconds"]),
                }
                for row in data
            ]
        else:
            output_data = [
                {
                    "app_name": row["app_name"],
                    "duration_seconds": row["duration_seconds"],
                    "start_time": row["start_time"].isoformat() if row["start_time"] else None,
                    "end_time": row["end_time"].isoformat() if row["end_time"] else None,
                }
                for row in data
            ]

        return StreamingResponse(
            iter([json.dumps(output_data, indent=2)]),
            media_type="application/json",
            headers={"Content-Disposition": f"attachment; filename={filename}.json"},
        )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
