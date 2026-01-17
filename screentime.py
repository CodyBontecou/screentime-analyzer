#!/usr/bin/env python3
"""
Screen Time Analyzer - Extract and analyze macOS Screen Time data from knowledgeC.db

This tool reads the macOS Screen Time database and provides app usage statistics.
Requires Full Disk Access permission in System Preferences > Privacy & Security.
"""

import argparse
import csv
import json
import os
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

# Apple Core Data epoch offset (seconds between 2001-01-01 and 1970-01-01)
APPLE_EPOCH_OFFSET = 978307200

# Default database location
DEFAULT_DB_PATH = Path.home() / "Library/Application Support/Knowledge/knowledgeC.db"


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
    """
    Copy the database to a temporary location to avoid locking issues.
    The knowledgeC.db is often locked by the system.
    """
    temp_dir = tempfile.mkdtemp(prefix="screentime_")
    temp_db = Path(temp_dir) / "knowledgeC.db"

    # Copy main database file
    shutil.copy2(db_path, temp_db)

    # Also copy WAL and SHM files if they exist (for consistency)
    for suffix in ["-wal", "-shm"]:
        wal_file = db_path.parent / (db_path.name + suffix)
        if wal_file.exists():
            shutil.copy2(wal_file, temp_db.parent / (temp_db.name + suffix))

    return temp_db


def get_app_usage(
    db_path: Path,
    start_date: Optional[datetime] = None,
    end_date: Optional[datetime] = None
) -> list[dict]:
    """
    Extract app usage data from the knowledgeC.db database.

    Returns a list of dicts with: app_name, duration_seconds, start_time, end_time
    """
    # Build the query
    query = """
        SELECT
            ZVALUESTRING as app_name,
            ZENDDATE - ZSTARTDATE as duration_seconds,
            ZSTARTDATE as start_timestamp,
            ZENDDATE as end_timestamp
        FROM ZOBJECT
        WHERE ZSTREAMNAME = '/app/usage'
            AND ZVALUESTRING IS NOT NULL
    """

    params = []

    if start_date:
        query += " AND ZSTARTDATE >= ?"
        params.append(datetime_to_apple_time(start_date))

    if end_date:
        query += " AND ZENDDATE <= ?"
        params.append(datetime_to_apple_time(end_date))

    query += " ORDER BY ZSTARTDATE DESC"

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row

    try:
        cursor = conn.execute(query, params)
        results = []

        for row in cursor:
            results.append({
                "app_name": row["app_name"],
                "duration_seconds": row["duration_seconds"] or 0,
                "start_time": apple_time_to_datetime(row["start_timestamp"]),
                "end_time": apple_time_to_datetime(row["end_timestamp"]),
            })

        return results
    finally:
        conn.close()


def aggregate_by_app(usage_data: list[dict]) -> list[dict]:
    """Aggregate usage data by app, summing total duration."""
    app_totals = {}

    for entry in usage_data:
        app = entry["app_name"]
        if app not in app_totals:
            app_totals[app] = 0
        app_totals[app] += entry["duration_seconds"]

    # Convert to list and sort by duration descending
    result = [
        {"app_name": app, "total_duration_seconds": duration}
        for app, duration in app_totals.items()
    ]
    result.sort(key=lambda x: x["total_duration_seconds"], reverse=True)

    return result


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


def export_csv(data: list[dict], output_path: Path, summary_mode: bool = False):
    """Export data to CSV file."""
    if not data:
        print("No data to export.", file=sys.stderr)
        return

    with open(output_path, "w", newline="", encoding="utf-8") as f:
        if summary_mode:
            fieldnames = ["app_name", "total_duration_seconds", "total_duration_formatted"]
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for row in data:
                writer.writerow({
                    "app_name": row["app_name"],
                    "total_duration_seconds": row["total_duration_seconds"],
                    "total_duration_formatted": format_duration(row["total_duration_seconds"]),
                })
        else:
            fieldnames = ["app_name", "duration_seconds", "start_time", "end_time"]
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for row in data:
                writer.writerow({
                    "app_name": row["app_name"],
                    "duration_seconds": row["duration_seconds"],
                    "start_time": row["start_time"].isoformat() if row["start_time"] else "",
                    "end_time": row["end_time"].isoformat() if row["end_time"] else "",
                })


def export_json(data: list[dict], output_path: Path, summary_mode: bool = False):
    """Export data to JSON file."""
    output_data = []

    if summary_mode:
        for row in data:
            output_data.append({
                "app_name": row["app_name"],
                "total_duration_seconds": row["total_duration_seconds"],
                "total_duration_formatted": format_duration(row["total_duration_seconds"]),
            })
    else:
        for row in data:
            output_data.append({
                "app_name": row["app_name"],
                "duration_seconds": row["duration_seconds"],
                "start_time": row["start_time"].isoformat() if row["start_time"] else None,
                "end_time": row["end_time"].isoformat() if row["end_time"] else None,
            })

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output_data, f, indent=2)


def print_daily_summary(usage_data: list[dict], top_n: int = 10):
    """Pretty-print a daily summary showing top apps by usage time."""
    if not usage_data:
        print("No usage data found for the specified period.")
        return

    # Group by date
    daily_data = {}
    for entry in usage_data:
        if entry["start_time"]:
            date_key = entry["start_time"].date()
            if date_key not in daily_data:
                daily_data[date_key] = {}

            app = entry["app_name"]
            if app not in daily_data[date_key]:
                daily_data[date_key][app] = 0
            daily_data[date_key][app] += entry["duration_seconds"]

    # Sort dates in descending order
    sorted_dates = sorted(daily_data.keys(), reverse=True)

    for date in sorted_dates:
        apps = daily_data[date]
        sorted_apps = sorted(apps.items(), key=lambda x: x[1], reverse=True)[:top_n]

        total_time = sum(apps.values())

        print(f"\n{'=' * 60}")
        print(f"  {date.strftime('%A, %B %d, %Y')}")
        print(f"  Total Screen Time: {format_duration(total_time)}")
        print(f"{'=' * 60}")

        if sorted_apps:
            # Find the longest app name for alignment
            max_name_len = min(40, max(len(app) for app, _ in sorted_apps))

            for i, (app, duration) in enumerate(sorted_apps, 1):
                # Truncate long app names
                display_name = app[:40] + "..." if len(app) > 40 else app
                bar_length = int((duration / sorted_apps[0][1]) * 20) if sorted_apps[0][1] > 0 else 0
                bar = "█" * bar_length

                print(f"  {i:2}. {display_name:<43} {format_duration(duration):>10}  {bar}")

        print()


def parse_date(date_str: str) -> datetime:
    """Parse date string in YYYY-MM-DD format."""
    try:
        return datetime.strptime(date_str, "%Y-%m-%d")
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"Invalid date format: '{date_str}'. Use YYYY-MM-DD format."
        )


def main():
    parser = argparse.ArgumentParser(
        description="Extract and analyze Screen Time data from macOS knowledgeC.db",
        epilog="""
NOTE: This tool requires Full Disk Access permission to read the Screen Time database.
Grant access in System Preferences > Privacy & Security > Full Disk Access.

Examples:
  %(prog)s                          Show daily summary for all time
  %(prog)s --start-date 2024-01-01  Show data from January 1, 2024
  %(prog)s --summary --format csv --output usage.csv
                                    Export aggregated app usage to CSV
  %(prog)s --format json -o data.json
                                    Export detailed usage to JSON
        """,
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument(
        "--start-date",
        type=parse_date,
        help="Filter results from this date (YYYY-MM-DD format)"
    )

    parser.add_argument(
        "--end-date",
        type=parse_date,
        help="Filter results until this date (YYYY-MM-DD format)"
    )

    parser.add_argument(
        "--format",
        choices=["csv", "json"],
        help="Output format (csv or json). If not specified, prints summary to terminal."
    )

    parser.add_argument(
        "-o", "--output",
        type=Path,
        help="Output file path (required when --format is specified)"
    )

    parser.add_argument(
        "--summary",
        action="store_true",
        help="Aggregate usage by app instead of showing individual sessions"
    )

    parser.add_argument(
        "--top",
        type=int,
        default=10,
        help="Number of top apps to show in daily summary (default: 10)"
    )

    parser.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB_PATH,
        help=f"Path to knowledgeC.db (default: {DEFAULT_DB_PATH})"
    )

    args = parser.parse_args()

    # Validate arguments
    if args.format and not args.output:
        parser.error("--output is required when --format is specified")

    if args.output and not args.format:
        parser.error("--format is required when --output is specified")

    # Check if database exists
    if not args.db.exists():
        print(f"Error: Database not found at {args.db}", file=sys.stderr)
        print("\nPossible causes:", file=sys.stderr)
        print("  - Screen Time may not be enabled on this Mac", file=sys.stderr)
        print("  - The database path may be different on your system", file=sys.stderr)
        print("  - You may need Full Disk Access permission", file=sys.stderr)
        sys.exit(1)

    # Copy database to temp to avoid locking issues
    temp_db = None
    try:
        print("Copying database to avoid lock issues...", file=sys.stderr)
        temp_db = copy_database_to_temp(args.db)

        # Adjust end_date to include the entire day
        end_date = args.end_date
        if end_date:
            end_date = end_date + timedelta(days=1) - timedelta(seconds=1)

        # Fetch data
        print("Reading Screen Time data...", file=sys.stderr)
        usage_data = get_app_usage(temp_db, args.start_date, end_date)

        if not usage_data:
            print("No Screen Time data found for the specified period.", file=sys.stderr)
            sys.exit(0)

        print(f"Found {len(usage_data)} usage records.", file=sys.stderr)

        # Process based on mode
        if args.format:
            # Export mode
            if args.summary:
                data = aggregate_by_app(usage_data)
            else:
                data = usage_data

            if args.format == "csv":
                export_csv(data, args.output, args.summary)
            else:
                export_json(data, args.output, args.summary)

            print(f"Data exported to {args.output}", file=sys.stderr)
        else:
            # Terminal display mode
            if args.summary:
                # Show overall summary
                data = aggregate_by_app(usage_data)
                total_time = sum(d["total_duration_seconds"] for d in data)

                print(f"\n{'=' * 60}")
                print(f"  Screen Time Summary")
                if args.start_date:
                    print(f"  From: {args.start_date.strftime('%Y-%m-%d')}")
                if args.end_date:
                    print(f"  To: {args.end_date.strftime('%Y-%m-%d')}")
                print(f"  Total Screen Time: {format_duration(total_time)}")
                print(f"{'=' * 60}")

                for i, entry in enumerate(data[:args.top], 1):
                    app = entry["app_name"]
                    duration = entry["total_duration_seconds"]
                    display_name = app[:40] + "..." if len(app) > 40 else app
                    bar_length = int((duration / data[0]["total_duration_seconds"]) * 20) if data[0]["total_duration_seconds"] > 0 else 0
                    bar = "█" * bar_length
                    print(f"  {i:2}. {display_name:<43} {format_duration(duration):>10}  {bar}")
                print()
            else:
                # Show daily breakdown
                print_daily_summary(usage_data, args.top)

    except PermissionError as e:
        print(f"Error: Permission denied accessing database.", file=sys.stderr)
        print("\nTo fix this, grant Full Disk Access to your terminal:", file=sys.stderr)
        print("  1. Open System Preferences > Privacy & Security", file=sys.stderr)
        print("  2. Select 'Full Disk Access' in the sidebar", file=sys.stderr)
        print("  3. Add your terminal application (Terminal, iTerm2, etc.)", file=sys.stderr)
        sys.exit(1)

    except sqlite3.DatabaseError as e:
        print(f"Error: Could not read database: {e}", file=sys.stderr)
        sys.exit(1)

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    finally:
        # Clean up temp database
        if temp_db and temp_db.exists():
            shutil.rmtree(temp_db.parent, ignore_errors=True)


if __name__ == "__main__":
    main()
