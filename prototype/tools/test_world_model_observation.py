import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


TOOLS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("world_model_map", TOOLS / "Map-WorldModelObservation.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
MANIFEST = TOOLS.parent / "fixtures/geodata/helsinki-kamppi-textured/manifest.json"
LARGE_MANIFEST = TOOLS.parent / "fixtures/geodata/helsinki-kamppi-250m/manifest.json"


class WorldModelMappingTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        self.batch = {
            "schema_version": 1, "batch_id": "experiment-001", "source_id": "flood-observer",
            "model_id": "flood-model", "model_version": "1.0.0",
            "source_crs": "EPSG:3879+5773", "horizontal_unit": "metre",
            "vertical_unit": "metre", "observed_at": "2026-09-25T08:00:00Z",
            "generated_at": "2026-09-25T08:05:00Z", "predicted_for": "2026-09-25T09:00:00Z",
            "samples": [{"id": "p1", "east": 5375.0, "north": 4150.0,
                         "water_surface_height": 1.725981348}],
        }
        self.as_of = MODULE.timestamp("2026-09-25T08:10:00Z")

    def map(self, manifest, batch):
        return MODULE.map_observation(manifest, batch, self.as_of, "flood-model", "1.0.0")

    def test_coordinates_and_source_evidence(self):
        record = self.map(self.manifest, self.batch)
        self.assertEqual(record["samples"][0]["region_position"], [126.5, 88.25, 2.0])
        with tempfile.TemporaryDirectory() as directory:
            input_path = Path(directory) / "input.json"
            output_path = Path(directory) / "mapped.json"
            input_path.write_text(json.dumps(self.batch), encoding="utf-8")
            saved = MODULE.convert(MANIFEST, input_path, output_path, "2026-09-25T08:10:00Z", "flood-model", "1.0.0")
            self.assertEqual(saved, json.loads(output_path.read_text(encoding="utf-8")))
            self.assertEqual(len(saved["input_sha256"]), 64)
            with self.assertRaisesRegex(ValueError, "fresh output"):
                MODULE.convert(MANIFEST, input_path, output_path, "2026-09-25T08:10:00Z", "flood-model", "1.0.0")

    def test_incompatible_and_stale_input_is_rejected(self):
        changes = [
            ({"source_crs": "EPSG:4326"}, "CRS"),
            ({"vertical_unit": "feet"}, "unit"),
            ({"observed_at": "2026-09-23T08:00:00Z"}, "stale"),
            ({"model_version": ""}, "model_version"),
            ({"model_version": "2.0.0"}, "incompatible"),
            ({"predicted_for": "2026-09-30T09:00:00Z"}, "horizon"),
        ]
        for update, message in changes:
            batch = copy.deepcopy(self.batch)
            batch.update(update)
            with self.subTest(update=update), self.assertRaisesRegex(ValueError, message):
                self.map(self.manifest, batch)

    def test_full_scene_uses_its_own_origin_and_height_baseline(self):
        manifest = json.loads(LARGE_MANIFEST.read_text(encoding="utf-8"))
        self.batch["samples"][0].update(east=5375.0, north=4125.0, water_surface_height=1.0)
        record = self.map(manifest, self.batch)
        self.assertEqual(record["samples"][0]["region_position"], [253.0, 253.0, 3.08826138])

    def test_outside_duplicate_and_unknown_fields_are_rejected(self):
        for mutation, message in [
            (lambda b: b["samples"][0].update(east=9999), "outside"),
            (lambda b: b["samples"].append(copy.deepcopy(b["samples"][0])), "repeated"),
            (lambda b: b.update(secret="unknown"), "fields"),
        ]:
            batch = copy.deepcopy(self.batch)
            mutation(batch)
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                self.map(self.manifest, batch)


if __name__ == "__main__":
    unittest.main()
