"""
Cron-based scheduler with Iceberg snapshot change detection.

Before triggering a materialization run, compares the current
Iceberg snapshot ID of each source table against the last-seen
snapshot ID. If nothing has changed, the run is skipped entirely.
"""
