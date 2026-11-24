import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ShelfInteractionTests(unittest.TestCase):
    def test_native_controls_approach_geometry_and_late_screenshot_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            environment = os.environ.copy()
            environment["CLANG_MODULE_CACHE_PATH"] = str(directory / "module-cache")
            environment["SWIFT_MODULECACHE_PATH"] = str(directory / "module-cache")
            sources = [
                "DynamicIsland/components/Shelf/Services/ShelfDragApproachGeometry.swift",
                "DynamicIsland/components/Shelf/Views/ShelfRemoveControl.swift",
                "DynamicIsland/managers/SavedScreenshotScanner.swift",
                "tests/ShelfInteractionRegression.swift",
            ]
            executable = directory / "shelf-interactions"
            subprocess.run(
                ["swiftc", *[str(ROOT / source) for source in sources], "-o", str(executable)],
                check=True, cwd=ROOT, env=environment,
            )
            subprocess.run([str(executable)], check=True, cwd=ROOT)


if __name__ == "__main__":
    unittest.main()
