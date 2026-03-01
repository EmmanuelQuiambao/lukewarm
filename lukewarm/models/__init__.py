"""
Model parsing and DAG construction.

Reads .sql model files, extracts ref() dependencies,
and builds a directed acyclic graph for materialization ordering.
"""
