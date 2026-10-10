"""Build and ad-hoc sign an interactive test bundle; never launch or request access."""
import json
from pathlib import Path
import plistlib
import subprocess


def main():
    root = Path(__file__).resolve().parents[2]
    bundle = root / "tmp/research/VoiceOSRemindersProbe.app"
    contents = bundle / "Contents"
    binary = contents / "MacOS/VoiceOSRemindersProbe"
    binary.parent.mkdir(parents=True, exist_ok=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.voiceos.reminders-probe",
        "CFBundleName": "VoiceOSRemindersProbe", "CFBundleExecutable": binary.name,
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSMinimumSystemVersion": "26.0",
        "NSRemindersFullAccessUsageDescription": "读取清单名称并在你选择的空白测试清单验证一个合成任务；系统权限覆盖所有提醒事项。",
        "NSRemindersUsageDescription": "在你选择的测试清单验证合成任务。",
    }))
    subprocess.run(["/usr/bin/env", "-u", "SDKROOT", "xcrun", "--sdk", "macosx", "swiftc",
                    "-target", "arm64-apple-macosx26.0", "-parse-as-library",
                    str(root / "scripts/probes/reminders-probe.swift"), "-o", str(binary)], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(bundle)], check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(bundle)], check=True)
    print(json.dumps({"probe": "reminders-bundle-build-v1", "bundle_path": str(bundle),
                      "compiled": True, "ad_hoc_signature_verified": True, "launched": False,
                      "scope": "unsandboxed local experiment; no permission prompt, EventKit access, production signing or notarization validated"}, indent=2))


if __name__ == "__main__":
    main()
