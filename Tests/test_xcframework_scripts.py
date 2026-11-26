"""Exercise packaging flow with synthetic archives and stubbed build tools."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "Scripts/build-sdk.sh"
IMPORT_CHECKER = ROOT / "Scripts/check-sdk-import.py"


def project_phase():
    project = (ROOT / "SDK/FTPlayer.xcodeproj/project.pbxproj").read_text()
    match = re.search(r'shellScript = ("(?:[^"\\]|\\.)*");', project)
    if match is None:
        raise AssertionError("Missing XCFramework build phase")
    return json.loads(match.group(1))


FAKE_TOOL = r'''
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
trace = Path(os.environ["PACKAGING_TEST_TRACE"])
if Path(sys.argv[0]).name == "python3":
    if args[0] != os.environ["PACKAGING_TEST_CHECKER"]:
        raise SystemExit("Unexpected Python invocation")
    event = {"tool": "consumer", "package": args[1],
             "outputExists": Path(os.environ["PACKAGING_TEST_OUTPUT"]).exists()}
    with trace.open("a") as log:
        log.write(json.dumps(event) + "\n")
    raise SystemExit(int(os.environ.get("PACKAGING_TEST_CONSUMER_EXIT", "0")))

with trace.open("a") as log:
    log.write(json.dumps({"tool": "xcodebuild", "arguments": args}) + "\n")
if args[0] == "archive":
    archive = Path(args[args.index("-archivePath") + 1])
    framework = archive / "Products/Library/Frameworks/FTPlayer.framework"
    framework.mkdir(parents=True)
    (framework / "FTPlayer").write_text("synthetic framework")
elif args[0] == "-create-xcframework":
    output = Path(args[args.index("-output") + 1])
    output.mkdir(parents=True)
    (output / "package-marker").write_text("synthetic XCFramework")
else:
    raise SystemExit("Unexpected xcodebuild invocation")
'''


class FTPlayerXCFrameworkScriptTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ftplayer-packaging-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        for name in ("xcodebuild", "python3"):
            tool = self.tools / name
            tool.write_text("#!" + sys.executable + "\n" + textwrap.dedent(FAKE_TOOL))
            tool.chmod(0o755)
        self.trace = self.root / "trace.jsonl"
        self.output = self.root / "distribution/FTPlayer.xcframework"
        self.environment = dict(os.environ)
        self.environment.update({
            "PATH": str(self.tools) + os.pathsep + os.environ["PATH"],
            "TMPDIR": str(self.root) + os.sep,
            "PACKAGING_TEST_TRACE": str(self.trace),
            "PACKAGING_TEST_CHECKER": str(IMPORT_CHECKER),
            "PACKAGING_TEST_OUTPUT": str(self.output),
        })

    def events(self):
        return [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []

    def run_distribution(self, consumer_exit=0):
        environment = dict(self.environment, PACKAGING_TEST_CONSUMER_EXIT=str(consumer_exit))
        return subprocess.run(["bash", str(BUILD_SCRIPT), str(self.output)],
                              env=environment, capture_output=True, text=True)

    def run_phase(self, configuration, enabled="YES"):
        project = self.root / configuration / "SDK"
        distribution = project / "build/FTPlayer.xcframework"
        distribution.mkdir(parents=True)
        (distribution / "release-sentinel").write_text("verified distribution")
        products = self.root / configuration / "products"
        framework = products / (configuration + "-iphonesimulator") / "FTPlayer.framework"
        framework.mkdir(parents=True)
        (framework / "FTPlayer").write_text("synthetic simulator framework")
        # An old neighboring dSYM must not be included in a new package.
        framework.with_name(framework.name + ".dSYM").mkdir()
        environment = dict(self.environment, PROJECT_DIR=str(project),
                           PRODUCT_NAME="FTPlayer", FULL_PRODUCT_NAME="FTPlayer.framework",
                           BUILD_DIR=str(products), CONFIGURATION=configuration,
                           PLATFORM_NAME="iphonesimulator", TARGET_BUILD_DIR=str(framework.parent),
                           ACTION="build", FTPLAYER_CREATE_XCFRAMEWORK=enabled)
        result = subprocess.run(["bash", "-c", project_phase()], env=environment,
                                capture_output=True, text=True)
        return result, distribution, project / "build" / configuration / "FTPlayer.xcframework"

    def test_simulator_phase_preserves_distribution_package(self):
        for configuration in ("Debug", "Release"):
            with self.subTest(configuration=configuration):
                result, distribution, development = self.run_phase(configuration)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((distribution / "release-sentinel").exists(),
                                "A Simulator build replaced the distribution XCFramework")
                self.assertTrue((development / "package-marker").exists())
                for event in self.events():
                    if event["tool"] == "xcodebuild":
                        self.assertNotIn("-debug-symbols", event["arguments"])

    def test_failed_consumer_does_not_publish_package(self):
        result = self.run_distribution(consumer_exit=23)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertFalse(self.output.exists(), "A failed import check left a published SDK")

    def test_distribution_archives_both_platforms_without_dsym(self):
        result = self.run_distribution()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.output / "package-marker").exists())
        events = self.events()
        archives = [e["arguments"] for e in events if e["tool"] == "xcodebuild" and e["arguments"][0] == "archive"]
        self.assertEqual(len(archives), 2)
        self.assertEqual({args[args.index("-destination") + 1] for args in archives},
                         {"generic/platform=iOS", "generic/platform=iOS Simulator"})
        for args in archives:
            self.assertEqual(args[args.index("-scheme") + 1], "FTPlayer")
            for flag in ("SKIP_INSTALL=NO", "BUILD_LIBRARY_FOR_DISTRIBUTION=YES",
                         "CODE_SIGNING_ALLOWED=NO", "FTPLAYER_CREATE_XCFRAMEWORK=NO",
                         "DEBUG_INFORMATION_FORMAT=dwarf"):
                self.assertIn(flag, args)
        package = next(e["arguments"] for e in events if e["tool"] == "xcodebuild" and e["arguments"][0] == "-create-xcframework")
        self.assertEqual(package.count("-framework"), 2)
        self.assertNotIn("-debug-symbols", package)
        self.assertEqual(len([e for e in events if e["tool"] == "consumer"]), 1)

    def test_sdk_build_settings_disable_dsym(self):
        specification = (ROOT / "SDK/project.yml").read_text()
        project = (ROOT / "SDK/FTPlayer.xcodeproj/project.pbxproj").read_text()
        self.assertIn("DEBUG_INFORMATION_FORMAT: dwarf", specification)
        self.assertNotIn("dwarf-with-dsym", project)
        self.assertIn("DEBUG_INFORMATION_FORMAT = dwarf;", project)

    def test_existing_output_is_preserved_without_building(self):
        self.output.mkdir(parents=True)
        sentinel = self.output / "existing-package"
        sentinel.write_text("keep")
        result = self.run_distribution()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), "keep")
        self.assertEqual(self.events(), [])

    def test_disabled_phase_preserves_distribution_without_packaging(self):
        result, distribution, development = self.run_phase("Debug", enabled="NO")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((distribution / "release-sentinel").exists())
        self.assertFalse(development.exists())
        self.assertEqual(self.events(), [])

    def test_project_and_generation_spec_have_identical_phase(self):
        lines = (ROOT / "SDK/project.yml").read_text().splitlines()
        start = next(i for i, line in enumerate(lines) if line.strip() == "script: |")
        indent = len(lines[start]) - len(lines[start].lstrip())
        body = []
        for line in lines[start + 1:]:
            if line.strip() and len(line) - len(line.lstrip()) <= indent:
                break
            body.append(line)
        specification = textwrap.dedent("\n".join(body))
        self.assertEqual(project_phase().strip(), specification.strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
