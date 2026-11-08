import unittest
from pathlib import Path

from tools.automation.t148_catalogue_gate import (
    CROSS_SPECIES_PL_LABELS,
    FORBIDDEN_COMMON_NAMES_EN,
    parse_image_dimensions_and_mime,
)


class T148CatalogueGateTests(unittest.TestCase):
    def test_parse_png_and_jpeg_dimensions_and_mime(self):
        root = Path(__file__).resolve().parents[3]
        png_path = root / "catalogue/releases/skeleton-300-v1/media/38f7502c9ab287eb85467900.png"
        jpg_path = root / "catalogue/releases/skeleton-300-v1/media/48854fc7b2b6d711a508c396.jpg"
        w_png, h_png, mime_png = parse_image_dimensions_and_mime(png_path.read_bytes())
        self.assertEqual(mime_png, "image/png")
        self.assertGreater(w_png, 200)
        self.assertGreater(h_png, 200)

        w_jpg, h_jpg, mime_jpg = parse_image_dimensions_and_mime(jpg_path.read_bytes())
        self.assertEqual(mime_jpg, "image/jpeg")
        self.assertGreater(w_jpg, 200)
        self.assertGreater(h_jpg, 200)

    def test_constants_cover_known_audit_anomalies(self):
        self.assertIn("flowering perennial herbaceous bulbous plant", FORBIDDEN_COMMON_NAMES_EN)
        self.assertIn("rock crevices", FORBIDDEN_COMMON_NAMES_EN)
        self.assertIn("by its Māori name of tī", FORBIDDEN_COMMON_NAMES_EN)
        self.assertIn(("dracaena_braunii", "dracena sandera"), CROSS_SPECIES_PL_LABELS)
        self.assertIn(("begonia_corallina", "begonia koralowa"), CROSS_SPECIES_PL_LABELS)
        self.assertIn(("hoya_lanceolata", "hoja piękna"), CROSS_SPECIES_PL_LABELS)


if __name__ == "__main__":
    unittest.main()
