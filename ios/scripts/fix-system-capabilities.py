#!/usr/bin/env python3
"""Repair XcodeGen 2.45 nested SystemCapabilities serialization."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: fix-system-capabilities.py <project.pbxproj>")

    project = Path(sys.argv[1])
    source = project.read_text(encoding="utf-8")
    pattern = re.compile(
        r'^(?P<indent>[ \t]*)SystemCapabilities = "(?P<body>[^\n]*)";$',
        re.MULTILINE,
    )
    matches = [
        match
        for match in pattern.finditer(source)
        if "com.apple.iCloud" in match.group("body")
        and "com.apple.Push" in match.group("body")
        and match.group("body").count("enabled") == 2
    ]
    if len(matches) != 2:
        raise SystemExit(
            "expected exactly two malformed iCloud/Push SystemCapabilities entries; "
            "inspect the generated project and retire or update this XcodeGen workaround"
        )

    def replacement(match: re.Match[str]) -> str:
        indent = match.group("indent")
        return "\n".join(
            [
                f"{indent}SystemCapabilities = {{",
                f"{indent}\tcom.apple.iCloud = {{",
                f"{indent}\t\tenabled = 1;",
                f"{indent}\t}};",
                f"{indent}\tcom.apple.Push = {{",
                f"{indent}\t\tenabled = 1;",
                f"{indent}\t}};",
                f"{indent}}};",
            ]
        )

    repaired = pattern.sub(replacement, source)
    project.write_text(repaired, encoding="utf-8")


if __name__ == "__main__":
    main()
