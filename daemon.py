#!/usr/bin/env python3
"""
TODO Notification Daemon
Scans markdown files for TODOs and sends desktop notifications
"""

import re
import time
import subprocess
import argparse
from datetime import datetime
from pathlib import Path
import logging


class TodoDaemon:
    def __init__(self, watch_dirs, check_interval=3600):
        self.watch_dirs = [Path(d).expanduser() for d in watch_dirs]
        self.check_interval = check_interval  # seconds
        self.logger = self.setup_logging()

    def setup_logging(self):
        logging.basicConfig(
            level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s"
        )
        return logging.getLogger(__name__)

    def find_markdown_files(self):
        """Find all markdown files in watch directories"""
        md_files = []
        for watch_dir in self.watch_dirs:
            if watch_dir.exists():
                md_files.extend(watch_dir.rglob("*.md"))
                md_files.extend(watch_dir.rglob("*.markdown"))
        return md_files

    def parse_todos(self, file_path):
        """Parse TODOs from a markdown file"""
        todos = []
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                for line_num, line in enumerate(f, 1):
                    # Match TODO:text@due(YYYY-MM-DD)
                    match = re.search(r"TODO:(.+?)@due\((\d{4}-\d{2}-\d{2})\)", line)
                    if match:
                        text = match.group(1).strip()
                        due_date = match.group(2)
                        todos.append(
                            {
                                "text": text,
                                "due": due_date,
                                "file": str(file_path),
                                "line": line_num,
                            }
                        )
        except Exception as e:
            self.logger.error(f"Error reading {file_path}: {e}")

        return todos

    def send_notification(self, title, message, urgency="normal"):
        """Send desktop notification using notify-send"""
        try:
            subprocess.run(
                [
                    "notify-send",
                    "-u",
                    urgency,
                    "-t",
                    "10000",  # 10 second timeout
                    title,
                    message,
                ],
                check=True,
            )
        except subprocess.CalledProcessError as e:
            self.logger.error(f"Failed to send notification: {e}")
        except FileNotFoundError:
            self.logger.error("notify-send not found. Please install libnotify-bin")

    def sync_to_taskwarrior(self, todos):
        """Sync TODOs to TaskWarrior"""
        if not todos:
            return

        synced = 0
        for todo in todos:
            try:
                # Check if task already exists (basic check by description)
                check_cmd = ["task", "_get", f"description:{todo['text']}", "due"]
                result = subprocess.run(check_cmd, capture_output=True, text=True)

                if result.returncode != 0:  # Task doesn't exist
                    add_cmd = [
                        "task",
                        "add",
                        todo["text"],
                        f"due:{todo['due']}",
                        f"project:TODO",
                        f"annotation:From {todo['file']}:{todo['line']}",
                    ]
                    subprocess.run(add_cmd, check=True)
                    synced += 1

            except subprocess.CalledProcessError as e:
                self.logger.error(f"TaskWarrior sync failed for '{todo['text']}': {e}")

        if synced > 0:
            self.send_notification("TaskWarrior", f"Synced {synced} new TODOs")

    def check_due_tasks(self):
        """Check all TODOs and notify about due/overdue ones"""
        all_todos = []

        # Collect all TODOs
        for md_file in self.find_markdown_files():
            todos = self.parse_todos(md_file)
            all_todos.extend(todos)

        if not all_todos:
            self.logger.info("No TODOs found")
            return

        now = datetime.now()
        due_soon = []
        overdue = []

        for todo in all_todos:
            try:
                due_date = datetime.strptime(todo["due"], "%Y-%m-%d")
                diff = due_date - now

                if diff.days < 0:
                    overdue.append(todo)
                elif diff.days == 0 or (
                    diff.days == 1 and now.hour >= 18
                ):  # Due today or tomorrow evening
                    due_soon.append(todo)

            except ValueError:
                self.logger.error(f"Invalid date format: {todo['due']}")

        # Send notifications
        if overdue:
            for todo in overdue:
                self.send_notification(
                    "TODO Overdue!",
                    f"{todo['text']}\nWas due: {todo['due']}\nFile: {Path(todo['file']).name}",
                    "critical",
                )

        if due_soon:
            for todo in due_soon:
                self.send_notification(
                    "TODO Due Soon",
                    f"{todo['text']}\nDue: {todo['due']}\nFile: {Path(todo['file']).name}",
                    "normal",
                )

        self.logger.info(
            f"Checked {len(all_todos)} TODOs - {len(overdue)} overdue, {len(due_soon)} due soon"
        )

        # Sync to TaskWarrior if available
        try:
            subprocess.run(["task", "--version"], capture_output=True, check=True)
            self.sync_to_taskwarrior(all_todos)
        except (subprocess.CalledProcessError, FileNotFoundError):
            self.logger.info("TaskWarrior not available, skipping sync")

    def run_daemon(self):
        """Run the daemon loop"""
        self.logger.info(f"Starting TODO daemon, watching: {self.watch_dirs}")
        self.logger.info(f"Check interval: {self.check_interval} seconds")

        while True:
            try:
                self.check_due_tasks()
                time.sleep(self.check_interval)
            except KeyboardInterrupt:
                self.logger.info("Daemon stopped by user")
                break
            except Exception as e:
                self.logger.error(f"Unexpected error: {e}")
                time.sleep(60)  # Wait a minute before retrying


def main():
    parser = argparse.ArgumentParser(description="TODO Notification Daemon")
    parser.add_argument(
        "directories", nargs="+", help="Directories to watch for markdown files"
    )
    parser.add_argument(
        "-i",
        "--interval",
        type=int,
        default=3600,
        help="Check interval in seconds (default: 3600 = 1 hour)",
    )
    parser.add_argument(
        "--once", action="store_true", help="Run once and exit (don't run as daemon)"
    )

    args = parser.parse_args()

    daemon = TodoDaemon(args.directories, args.interval)

    if args.once:
        daemon.check_due_tasks()
    else:
        daemon.run_daemon()


if __name__ == "__main__":
    main()
