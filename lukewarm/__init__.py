"""
Lukewarm — cost-effective declarative SQL models over Apache Iceberg.

Hot/cold read pattern: cold = last materialized Iceberg snapshot,
hot = delta since last snapshot. Lukewarm merges both at query time.
"""

__version__ = "0.1.0"
