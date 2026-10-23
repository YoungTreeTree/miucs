#!/usr/bin/env python3
"""Validate synthetic fixtures and Swift round-trips without network access."""
import copy
import json
from pathlib import Path

try:
    from jsonschema import Draft202012Validator, FormatChecker
    from referencing import Registry, Resource
except ImportError as error:
    raise SystemExit("Install test dependencies: python3 -m pip install -r tests/requirements.txt") from error

root = Path(__file__).resolve().parent.parent
base = root / "contracts/audio-features"
schemas = [json.loads((base / name).read_text()) for name in ("frame.schema.json", "input.schema.json")]
registry = Registry().with_resources((schema["$id"], Resource.from_contents(schema)) for schema in schemas)
for schema in schemas:
    Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schemas[1], registry=registry, format_checker=FormatChecker())
files = sorted((base / "samples").glob("*.json")) + sorted((root / "build/contracts/round-trip").glob("*.json"))
for path in files:
    value = json.loads(path.read_text())
    validator.validate(value)
    frame = value.get("frame")
    if frame:
        assert frame["sessionID"] == value["sessionID"], path
        assert value.get("frameAge") is not None, path
        assert all(event["sequence"] <= frame["sequence"] for event in value["onsets"]), path
        assert value["onsets"] == sorted(value["onsets"], key=lambda event: event["sequence"]), path

valid = json.loads((base / "samples/01-melodic-stereo.json").read_text())
invalid = []
for field, value in (("version", 2), ("state", "unknown"), ("sessionID", "not-a-uuid"),
                     ("frameAge", -1), ("spectralFluxPeak", 2), ("nativeView", "NSView")):
    mutated = copy.deepcopy(valid)
    mutated[field] = value
    invalid.append(mutated)
mutated = copy.deepcopy(valid)
mutated["frame"]["audio"]["displayBands"] = [0] * 23
invalid.append(mutated)
mutated = copy.deepcopy(valid)
mutated["onsets"] = [dict(sequence=1, time=0, receivedAt=100, strength=0.2)] * 65
invalid.append(mutated)
assert all(not validator.is_valid(value) for value in invalid), "Invalid data accepted"
print(f"PASS JSON Schema ({len(files)} fixtures/round-trips, {len(invalid)} invalid inputs rejected; local schema registry)")
