"""
Query rewriter.

Takes a declarative SQL model and rewrites it to read from
the last cold (materialized) Iceberg snapshot plus the hot
(delta) changes since that snapshot.
"""
