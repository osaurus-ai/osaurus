"""Shared utilities for LOCOMO benchmark scripts."""

import uuid


def sample_id_to_uuid(sample_id: str) -> str:
    """Deterministic agent UUID from a LOCOMO sample ID."""
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"locomo.{sample_id}"))
