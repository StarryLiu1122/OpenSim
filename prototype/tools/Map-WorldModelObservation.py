"""Validate and map one external water-level prediction into Region Lab coordinates.

This is an offline V6.1 input boundary. It never mutates a world; a later FP-06
adapter can consume the normalized, content-addressed record after review.
"""

import argparse
import hashlib
import json
import math
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path


IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$")
UTC_TIME = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")


def timestamp(value):
    if not isinstance(value, str) or not UTC_TIME.fullmatch(value):
        raise ValueError("times must use UTC YYYY-MM-DDTHH:MM:SSZ")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError as error:
        raise ValueError("invalid UTC timestamp") from error


def finite_number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{label} must be a finite number")
    return float(value)


def exact_keys(value, keys, label):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ValueError(f"{label} fields are missing or unknown")


def map_observation(manifest, batch, as_of, expected_model_id, expected_model_version):
    if not isinstance(manifest, dict) or not all(key in manifest for key in
            ("source_crs", "source_bounds", "region_offset", "height_baseline_source")):
        raise ValueError("scene manifest lacks its coordinate mapping")
    exact_keys(batch, ["schema_version", "batch_id", "source_id", "model_id",
                       "model_version", "source_crs", "horizontal_unit", "vertical_unit",
                       "observed_at", "generated_at", "predicted_for", "samples"], "batch")
    if type(batch["schema_version"]) is not int or batch["schema_version"] != 1:
        raise ValueError("unsupported observation schema version")
    for key in ("batch_id", "source_id", "model_id", "model_version"):
        if not isinstance(batch[key], str) or not IDENTIFIER.fullmatch(batch[key]):
            raise ValueError(f"invalid {key}")
    if batch["model_id"] != expected_model_id or batch["model_version"] != expected_model_version:
        raise ValueError("model identity or version is incompatible with the requested experiment")
    if batch["source_crs"] != manifest["source_crs"] or batch["source_crs"] != "EPSG:3879+5773":
        raise ValueError("source CRS or vertical datum is incompatible with this scene")
    if batch["horizontal_unit"] != "metre" or batch["vertical_unit"] != "metre":
        raise ValueError("unknown or incompatible coordinate unit")
    observed = timestamp(batch["observed_at"])
    generated = timestamp(batch["generated_at"])
    predicted = timestamp(batch["predicted_for"])
    if not observed <= generated <= as_of or as_of - observed > timedelta(hours=24):
        raise ValueError("observation is stale or generated in the future")
    if not generated <= predicted <= generated + timedelta(hours=72):
        raise ValueError("prediction time lies outside the 72-hour horizon")
    if not isinstance(batch["samples"], list) or not 1 <= len(batch["samples"]) <= 256:
        raise ValueError("expected 1–256 water-level samples")
    bounds = manifest["source_bounds"]
    offset = manifest["region_offset"]
    if not isinstance(bounds, list) or len(bounds) != 4 or not isinstance(offset, list) or len(offset) != 2:
        raise ValueError("scene manifest has invalid bounds or offset")
    bounds = [finite_number(value, "source bound") for value in bounds]
    offset = [finite_number(value, "region offset") for value in offset]
    if bounds[0] >= bounds[2] or bounds[1] >= bounds[3]:
        raise ValueError("scene manifest has inverted source bounds")
    baseline = finite_number(manifest["height_baseline_source"], "height baseline")
    region_size = finite_number(manifest.get("region_size", 256), "region size")
    mapped, seen = [], set()
    for sample in batch["samples"]:
        exact_keys(sample, ["id", "east", "north", "water_surface_height"], "sample")
        if not isinstance(sample["id"], str) or not IDENTIFIER.fullmatch(sample["id"]) or sample["id"] in seen:
            raise ValueError("invalid or repeated sample ID")
        seen.add(sample["id"])
        east = finite_number(sample["east"], "east")
        north = finite_number(sample["north"], "north")
        height = finite_number(sample["water_surface_height"], "water surface height")
        x, y, z = offset[0] + east - bounds[0], offset[1] + north - bounds[1], height - baseline
        if not bounds[0] <= east <= bounds[2] or not bounds[1] <= north <= bounds[3] or not 0 <= x <= region_size or not 0 <= y <= region_size or not -40 <= z <= 120:
            raise ValueError(f"sample {sample['id']} is outside the mapped scene")
        mapped.append({"id": sample["id"], "source_position": [east, north, height],
                       "region_position": [x, y, z]})
    return {"format": "region-lab.world-model-input", "version": 1,
            "batch_id": batch["batch_id"], "source_id": batch["source_id"],
            "model_id": batch["model_id"], "model_version": batch["model_version"],
            "source_crs": batch["source_crs"], "observed_at": batch["observed_at"],
            "generated_at": batch["generated_at"], "predicted_for": batch["predicted_for"],
            "samples": mapped}


def convert(manifest_path, input_path, output_path, as_of, expected_model_id, expected_model_version):
    if output_path.exists():
        raise ValueError("use a fresh output path")
    if manifest_path.stat().st_size > 1024 * 1024 or input_path.stat().st_size > 1024 * 1024:
        raise ValueError("mapping input exceeds the 1 MiB limit")
    manifest_bytes = manifest_path.read_bytes()
    input_bytes = input_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    batch = json.loads(input_bytes)
    record = map_observation(manifest, batch, timestamp(as_of), expected_model_id, expected_model_version)
    record["manifest_sha256"] = hashlib.sha256(manifest_bytes).hexdigest()
    record["input_sha256"] = hashlib.sha256(input_bytes).hexdigest()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return record


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--as-of", required=True, help="Audit time in UTC, YYYY-MM-DDTHH:MM:SSZ")
    parser.add_argument("--model-id", required=True, help="Expected model identity for this experiment")
    parser.add_argument("--model-version", required=True, help="Expected model version for this experiment")
    args = parser.parse_args()
    result = convert(args.manifest, args.input, args.output, args.as_of, args.model_id, args.model_version)
    print(f"Mapped {len(result['samples'])} observations from batch {result['batch_id']}.")
