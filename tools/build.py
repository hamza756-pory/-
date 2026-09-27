#!/usr/bin/env python3
"""Package Rafiq: inject UI, write docs demo, build EXE, zip."""

from __future__ import annotations

import base64
import hashlib
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from mkexe import build_pe  # noqa: E402


def sha256(p: Path) -> str:
    h = hashlib.sha256()
    h.update(p.read_bytes())
    return h.hexdigest()


def main() -> int:
    icon64 = ROOT / "assets" / "icon-64.png"
    icon256 = ROOT / "assets" / "icon-256.png"
    html = (ROOT / "web" / "index.html").read_text(encoding="utf-8")
    data_uri = "data:image/png;base64," + base64.b64encode(icon64.read_bytes()).decode("ascii")
    html_app = html.replace("__ICON_SRC__", data_uri).replace("__FAVICON__", data_uri)

    docs = ROOT / "docs"
    docs.mkdir(exist_ok=True)
    (docs / "assets").mkdir(exist_ok=True)
    (docs / "assets" / "icon.png").write_bytes(icon256.read_bytes())
    (docs / "assets" / "favicon.png").write_bytes(icon64.read_bytes())
    html_web = html.replace("__ICON_SRC__", "assets/icon.png").replace("__FAVICON__", "assets/favicon.png")
    (docs / "app.html").write_text(html_web, encoding="utf-8")

    html_b64 = base64.b64encode(html_app.encode("utf-8")).decode("ascii")
    ps1 = (ROOT / "src" / "Rafiq.ps1").read_text(encoding="utf-8")
    if "__HTML_B64__" not in ps1:
        raise SystemExit("Rafiq.ps1 missing __HTML_B64__ placeholder")
    ps1_built = ps1.replace("__HTML_B64__", html_b64)
    built_ps1 = ROOT / "dist" / "RafiqUI.ps1"
    built_ps1.parent.mkdir(exist_ok=True)
    # UTF-8 BOM for Windows PowerShell 5.1
    built_ps1.write_bytes(b"\xef\xbb\xbf" + ps1_built.encode("utf-8"))

    exe_path = ROOT / "dist" / "Rafiq.exe"
    exe_path.write_bytes(build_pe(built_ps1.read_bytes()))

    readme_txt = (ROOT / "dist" / "README.txt")
    readme_txt.write_text(
        """Rafiq 1.0.0 — Windows 10 / 11 repair companion
===============================================

Arabic / العربية
----------------
1) انقر نقراً مزدوجاً على Rafiq.exe
2) إذا حذر SmartScreen: المزيد من المعلومات → تشغيل على أي حال
   (البرنامج مفتوح المصدر وغير موقّع بشهادة مدفوعة)
3) إن لم يعمل exe شغّل RafiqUI.ps1 بزر أيمن → Run with PowerShell

English
-------
1) Double-click Rafiq.exe
2) If SmartScreen appears: More info → Run anyway
   (the app is open source and not Authenticode-signed)
3) Fallback: right-click RafiqUI.ps1 → Run with PowerShell

The UI is served only on http://127.0.0.1 (this PC). No telemetry.

License: MIT  |  https://github.com/hamza756-pory/-
""",
        encoding="utf-8",
    )

    license_txt = ROOT / "LICENSE"
    zip_path = ROOT / "dist" / "Rafiq-1.0.0-windows-x64.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(exe_path, "Rafiq/Rafiq.exe")
        z.write(built_ps1, "Rafiq/RafiqUI.ps1")
        z.write(readme_txt, "Rafiq/README.txt")
        if license_txt.exists():
            z.write(license_txt, "Rafiq/LICENSE.txt")
        ico = ROOT / "assets" / "rafiq.ico"
        if ico.exists():
            z.write(ico, "Rafiq/rafiq.ico")

    sums = ROOT / "dist" / "SHA256SUMS.txt"
    lines = []
    for p in (exe_path, zip_path, built_ps1):
        lines.append(f"{sha256(p)}  {p.name}")
    sums.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("EXE ", exe_path, exe_path.stat().st_size)
    print("ZIP ", zip_path, zip_path.stat().st_size)
    print("PS1 ", built_ps1.stat().st_size)
    print(sums.read_text())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
