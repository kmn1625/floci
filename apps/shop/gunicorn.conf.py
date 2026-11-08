"""Gunicorn hooks for the metrics both workers share (app.py, PROMETHEUS_MULTIPROC_DIR)."""
import os
import shutil


def on_starting(server):
    # Counters from a previous run would carry over and read as traffic that never happened.
    path = os.environ.get("PROMETHEUS_MULTIPROC_DIR")
    if path:
        shutil.rmtree(path, ignore_errors=True)
        os.makedirs(path)


def child_exit(server, worker):
    if os.environ.get("PROMETHEUS_MULTIPROC_DIR"):
        from prometheus_client import multiprocess

        multiprocess.mark_process_dead(worker.pid)
