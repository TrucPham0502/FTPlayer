#!/usr/bin/env python3
"""Compile an independent consumer against the shipped SDK and its text interfaces."""

import argparse
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("xcframework", type=Path)
    parser.add_argument("--work-dir", type=Path)
    parser.add_argument("--languages", default="default",
                        help="Comma-separated compiler language modes; default uses the compiler's default mode")
    args = parser.parse_args()
    package = args.xcframework.resolve()
    work = (args.work_dir or Path(tempfile.mkdtemp(prefix="FTPlayer-consumer-"))).resolve()
    if work == package or package in work.parents:
        parser.error("Consumer work directory must be outside the XCFramework")
    work.mkdir(parents=True, exist_ok=True)
    languages = [value.strip() for value in args.languages.split(",")]
    if any(not value for value in languages):
        parser.error("Language modes must not be empty")
    info = plistlib.loads((package / "Info.plist").read_bytes())
    consumer = work / "Consumer.swift"
    consumer.write_text("""import Foundation
import FTPlayer
final class ConsumerDelegate: FTPlayerDeletegate {
    func player(_ player: FTPlayer, didChangeState state: FTPlayerState) {}
    func player(_ player: FTPlayer, didUpdateProgress progress: TimeInterval) {}
    func player(_ player: FTPlayer, didChangePreparationState state: FTPlayerPreparationState) {}
}
@MainActor final class Consumer {
    weak var observer: (any FTPlayerDeletegate)?
    func configure() {
        FTPlayerDiagnostic.shared.isEnabled = true
        FTPlayerDiagnostic.shared.log("Consumer enabled diagnostics")
        FTPlayerDiagnostic.shared.isEnabled = FTPlayerSDKConfiguration.Diagnostics.enabledByDefault
        let observer = ConsumerDelegate()
        let player = FTPlayer(contentURL: nil)
        let renderer = FTMediaRendererView()
        player.videoOutput = renderer
        player.delegate = observer
        player.playbackDelegate = observer
        player.progressDelegate = observer
        player.preparationDelegate = observer
        player.rate = 1
        player.useCache = false
        let policy: FTVideoDecodingPolicy = .ffmpeg
        player.videoDecodingPolicy = policy
        let _: FTVideoDecodingStatistics = player.videoDecodingStatistics
        let _: FTPlayerCacheProgress = player.cacheProgress
        self.observer = observer
    }
}
""")
    checks = []
    for library in info["AvailableLibraries"]:
        if library["SupportedPlatform"] != "ios":
            raise SystemExit("Expected an iOS SDK slice: " + library["LibraryIdentifier"])
        variant = library.get("SupportedPlatformVariant")
        if variant not in (None, "simulator"):
            raise SystemExit("Unsupported iOS variant: " + str(variant))
        identifier = library["LibraryIdentifier"]
        framework = package / identifier / library["LibraryPath"]
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "iphonesimulator" if variant else "iphoneos", "--show-sdk-path"], text=True
        ).strip()
        deployment = plistlib.loads((framework / "Info.plist").read_bytes()).get("MinimumOSVersion", "13.0")
        for mode in ("packaged", "public-interface", "private-interface"):
            destination = work / identifier / mode / framework.name
            if destination.exists():
                shutil.rmtree(destination)
            shutil.copytree(framework, destination)
            modules = destination / "Modules/FTPlayer.swiftmodule"
            if mode != "packaged":
                # Only the SDK under test is copied. Vendor sources/binaries stay untouched.
                for path in modules.iterdir():
                    if path.is_file() and (path.suffix in (".swiftmodule", ".swiftdoc", ".swiftsourceinfo") or
                                           mode == "public-interface" and path.name.endswith(".private.swiftinterface")):
                        path.unlink()
                if not any(modules.glob("*.swiftinterface")):
                    raise SystemExit("SDK has no textual interface: " + identifier)
            for architecture in library["SupportedArchitectures"]:
                target = architecture + "-apple-ios" + deployment + ("-simulator" if variant else "")
                for language in languages:
                    name = identifier + "-" + mode + "-" + architecture + "-swift" + language
                    language_flags = [] if language == "default" else ["-swift-version", language]
                    command = ["xcrun", "swiftc", "-emit-library", str(consumer), "-target", target,
                               "-sdk", sdk, *language_flags, "-F", str(destination.parent),
                               "-module-cache-path", str(work / (name + "-cache")), "-o", str(work / (name + ".dylib"))]
                    result = subprocess.run(command, capture_output=True, text=True)
                    log = work / (name + ".log")
                    log.write_text(result.stdout + result.stderr)
                    checks.append({"slice": identifier, "mode": mode, "architecture": architecture,
                                   "language": language, "exitCode": result.returncode, "log": str(log)})
                    print(("PASS " if result.returncode == 0 else "FAIL ") + name, flush=True)
    compiler = subprocess.check_output(["xcrun", "swiftc", "--version"], text=True).strip()
    (work / "results.json").write_text(json.dumps({"package": str(package), "compiler": compiler, "checks": checks}, indent=2))
    print("Consumer results: " + str(work / "results.json"))
    return 0 if checks and all(check["exitCode"] == 0 for check in checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
