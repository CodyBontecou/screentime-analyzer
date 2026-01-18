#!/usr/bin/env python3
"""
Screen Time Sync - Upload macOS Screen Time data to remote server.

This script reads your local Screen Time data and uploads it to your
screentime-analyzer server for access from anywhere.

Usage:
    python sync_screentime.py --api-url https://your-server.fly.dev --api-key YOUR_KEY

Configuration:
    You can also set environment variables:
    - SCREENTIME_API_URL: Server URL
    - SCREENTIME_API_KEY: API key for authentication
"""

import argparse
import json
import os
import shutil
import sqlite3
import sys
import tempfile
import urllib.request
import urllib.error
from datetime import datetime, timedelta
from pathlib import Path

# Apple Core Data epoch offset (seconds between 2001-01-01 and 1970-01-01)
APPLE_EPOCH_OFFSET = 978307200

# Default database location
DEFAULT_DB_PATH = Path.home() / "Library/Application Support/Knowledge/knowledgeC.db"

# Config file location
CONFIG_PATH = Path.home() / ".config/screentime-sync/config.json"


def apple_time_to_datetime(apple_timestamp: float) -> datetime:
    """Convert Apple Core Data timestamp to Python datetime."""
    if apple_timestamp is None:
        return None
    unix_timestamp = apple_timestamp + APPLE_EPOCH_OFFSET
    return datetime.fromtimestamp(unix_timestamp)


def datetime_to_apple_time(dt: datetime) -> float:
    """Convert Python datetime to Apple Core Data timestamp."""
    return dt.timestamp() - APPLE_EPOCH_OFFSET


def copy_database_to_temp(db_path: Path) -> Path:
    """Copy the database to a temporary location to avoid locking issues."""
    temp_dir = tempfile.mkdtemp(prefix="screentime_sync_")
    temp_db = Path(temp_dir) / "knowledgeC.db"

    shutil.copy2(db_path, temp_db)

    for suffix in ["-wal", "-shm"]:
        wal_file = db_path.parent / (db_path.name + suffix)
        if wal_file.exists():
            shutil.copy2(wal_file, temp_db.parent / (temp_db.name + suffix))

    return temp_db


def get_usage_data(db_path: Path, days_back: int = 7) -> list[dict]:
    """Extract recent app usage data from knowledgeC.db."""
    start_date = datetime.now() - timedelta(days=days_back)

    query = """
        SELECT
            ZVALUESTRING as app_name,
            ZENDDATE - ZSTARTDATE as duration_seconds,
            ZSTARTDATE as start_timestamp,
            ZENDDATE as end_timestamp
        FROM ZOBJECT
        WHERE ZSTREAMNAME = '/app/usage'
            AND ZVALUESTRING IS NOT NULL
            AND ZSTARTDATE >= ?
        ORDER BY ZSTARTDATE DESC
    """

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    try:
        cursor = conn.execute(query, [datetime_to_apple_time(start_date)])
        results = []

        for row in cursor:
            start_time = apple_time_to_datetime(row["start_timestamp"])
            end_time = apple_time_to_datetime(row["end_timestamp"])

            results.append({
                "app_name": row["app_name"],
                "duration_seconds": row["duration_seconds"] or 0,
                "start_time": start_time.isoformat() if start_time else None,
                "end_time": end_time.isoformat() if end_time else None,
            })

        return results
    finally:
        conn.close()


def upload_data(api_url: str, api_key: str, records: list[dict]) -> dict:
    """Upload usage records to the server."""
    url = api_url.rstrip("/") + "/upload"

    data = json.dumps({"records": records}).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/json",
            "X-API-Key": api_key,
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        error_body = e.read().decode("utf-8")
        raise Exception(f"HTTP {e.code}: {error_body}")
    except urllib.error.URLError as e:
        raise Exception(f"Connection failed: {e.reason}")


def load_config() -> dict:
    """Load configuration from file."""
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            return json.load(f)
    return {}


def save_config(config: dict):
    """Save configuration to file."""
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=2)


def main():
    parser = argparse.ArgumentParser(
        description="Sync macOS Screen Time data to remote server",
        epilog="""
Examples:
  %(prog)s --api-url https://screentime.fly.dev --api-key abc123
  %(prog)s --days 30  # Sync last 30 days
  %(prog)s --save     # Save URL and key to config file
        """,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    parser.add_argument(
        "--api-url",
        help="Server URL (or set SCREENTIME_API_URL env var)",
    )

    parser.add_argument(
        "--api-key",
        help="API key for authentication (or set SCREENTIME_API_KEY env var)",
    )

    parser.add_argument(
        "--days",
        type=int,
        default=7,
        help="Number of days to sync (default: 7)",
    )

    parser.add_argument(
        "--save",
        action="store_true",
        help="Save API URL and key to config file for future use",
    )

    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress output except errors",
    )

    args = parser.parse_args()

    # Load config and merge with args/env
    config = load_config()

    api_url = (
        args.api_url
        or os.environ.get("SCREENTIME_API_URL")
        or config.get("api_url")
    )

    api_key = (
        args.api_key
        or os.environ.get("SCREENTIME_API_KEY")
        or config.get("api_key")
    )

    if not api_url:
        print("Error: API URL required. Use --api-url or set SCREENTIME_API_URL", file=sys.stderr)
        sys.exit(1)

    if not api_key:
        print("Error: API key required. Use --api-key or set SCREENTIME_API_KEY", file=sys.stderr)
        sys.exit(1)

    # Save config if requested
    if args.save:
        config["api_url"] = api_url
        config["api_key"] = api_key
        save_config(config)
        if not args.quiet:
            print(f"Configuration saved to {CONFIG_PATH}")

    # Check database exists
    if not DEFAULT_DB_PATH.exists():
        print(f"Error: Screen Time database not found at {DEFAULT_DB_PATH}", file=sys.stderr)
        print("Make sure Screen Time is enabled on this Mac.", file=sys.stderr)
        sys.exit(1)

    # Copy and read database
    temp_db = None
    try:
        if not args.quiet:
            print("Reading Screen Time data...")

        temp_db = copy_database_to_temp(DEFAULT_DB_PATH)
        records = get_usage_data(temp_db, args.days)

        if not records:
            if not args.quiet:
                print("No usage data found for the specified period.")
            sys.exit(0)

        if not args.quiet:
            print(f"Found {len(records)} records from the last {args.days} days")
            print(f"Uploading to {api_url}...")

        result = upload_data(api_url, api_key, records)

        if not args.quiet:
            print(f"Sync complete: {result['records_inserted']} new records uploaded")

    except PermissionError:
        print("Error: Permission denied. Grant Full Disk Access to your terminal.", file=sys.stderr)
        print("System Preferences > Privacy & Security > Full Disk Access", file=sys.stderr)
        sys.exit(1)

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    finally:
        if temp_db and temp_db.exists():
            shutil.rmtree(temp_db.parent, ignore_errors=True)


if __name__ == "__main__":
    main()
