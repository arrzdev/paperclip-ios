"""Copy attachments exported by `xcresulttool export attachments` under their test names.

Usage: name-attachments.py <export-dir> <output-dir>

The export folder holds files with generated names plus `manifest.json`; each
attachment's `suggestedHumanReadableName` is the name the test gave it (e.g.
`ax5-04-Me-Accounts_0_<uuid>.png`). Output: `<test>/<name>.<ext>`, with the
generated suffix removed. Any file the manifest does not describe is copied as is.
All "<screen> audit" texts are also collected into `<output-dir>/audit-report.md`.
"""

import json
import os
import re
import shutil
import sys


def safe(text):
    return re.sub(r"[^A-Za-z0-9._ -]+", "-", text).strip() or "attachment"


def main(source, target):
    os.makedirs(target, exist_ok=True)
    described = set()
    audits = []
    manifest_path = os.path.join(source, "manifest.json")
    if os.path.exists(manifest_path):
        with open(manifest_path) as handle:
            manifest = json.load(handle)
        for test in manifest:
            test_name = safe(test.get("testIdentifier", "test").split("/")[-1].replace("()", ""))
            folder = os.path.join(target, test_name)
            os.makedirs(folder, exist_ok=True)
            for attachment in test.get("attachments", []):
                exported = attachment.get("exportedFileName")
                if not exported:
                    continue
                described.add(exported)
                name = attachment.get("suggestedHumanReadableName") or exported
                stem, ext = os.path.splitext(name)
                stem = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", stem)
                ext = ext or os.path.splitext(exported)[1]
                shutil.copy(os.path.join(source, exported), os.path.join(folder, safe(stem) + ext))
                if stem.endswith(" audit") and ext == ".txt":
                    with open(os.path.join(source, exported)) as handle:
                        audits.append((stem[: -len(" audit")], handle.read().strip()))
    with open(os.path.join(target, "audit-report.md"), "w") as report:
        report.write("# Accessibility audit\n\nNEW = fails the test; known = in UITests/AccessibilityBaseline.json.\n")
        for screen, text in sorted(audits):
            report.write("\n## %s\n\n```\n%s\n```\n" % (screen, text))
    for name in os.listdir(source):
        if name != "manifest.json" and name not in described and os.path.isfile(os.path.join(source, name)):
            shutil.copy(os.path.join(source, name), os.path.join(target, name))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
