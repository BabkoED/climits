#!/usr/bin/env python3
"""Подписать выпущенный релиз и обновить лету Sparkle.

ЗАЧЕМ ЭТО ЗДЕСЬ, А НЕ В CI. Sparkle требует подписи EdDSA на архиве
обновления. Обычно это делает `sign_update` на macOS, а приватный ключ
кладут в секреты репозитория. Мы так не делаем: ключ остаётся на сервере,
в GitHub не попадает вовсе.

ПОЧЕМУ ЭТО РАБОТАЕТ. Приватный ключ Sparkle - это base64 от 32-байтового
зерна ed25519, и его собственная справка говорит, что зерно «можно
использовать с другими инструментами, поддерживающими EdDSA». Проверено
сверкой на macos-14 07.09.2026: подпись, посчитанная этим скриптом, сошлась
с выводом `sign_update` побайтово, и `sign_update --verify` её принял.

ПОРЯДОК ВЫПУСКА, два шага вместо одного:
  1. тег v* - CI на macOS собирает climits.zip и кладёт в релизы;
  2. этот скрипт - скачивает архив, подписывает, обновляет appcast.xml
     и толкает его в ветку appcast.

  python3 tools/sign-release.py v1.8.0

Ключ лежит в ~/harness/var/secrets/climits-sparkle.key и существует в
одном экземпляре. ПОТЕРЯ КЛЮЧА = самообновление через Sparkle мертво
навсегда: смена ключей у Sparkle возможна только для приложений,
подписанных Developer ID, а наше подписано ad-hoc. Поэтому первый путь
(через GitHub-релизы) из приложения не убран.
"""

import base64
import hashlib
import os
import pathlib
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET
from email.utils import format_datetime
from datetime import datetime, timezone

REPO = "BabkoED/climits"
KEY = pathlib.Path(os.path.expanduser("~/harness/var/secrets/climits-sparkle.key"))
FEED_BRANCH = "appcast"
FEED_NAME = "appcast.xml"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def die(msg):
    print("остановился: " + msg, file=sys.stderr)
    sys.exit(1)


def sign(data: bytes) -> str:
    """Подпись ровно та, что делает sign_update: ed25519 над байтами файла."""
    try:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    except ImportError:
        die("нужен модуль cryptography")
    if not KEY.exists():
        die(f"нет ключа: {KEY}")
    seed = base64.b64decode(KEY.read_text().strip())
    if len(seed) != 32:
        die(f"ключ не 32 байта, а {len(seed)} - это не зерно ed25519")
    return base64.b64encode(Ed25519PrivateKey.from_private_bytes(seed).sign(data)).decode()


def gh(path: str) -> dict:
    import json
    req = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}{path}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "climits-sign"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def main():
    if len(sys.argv) != 2:
        die("укажи тег: sign-release.py v1.8.0")
    tag = sys.argv[1]

    rel = gh(f"/releases/tags/{tag}")
    asset = next((a for a in rel.get("assets", []) if a["name"] == "climits.zip"), None)
    if not asset:
        die(f"в релизе {tag} нет climits.zip - сборка ещё идёт?")

    url = asset["browser_download_url"]
    print(f"качаю {url}")
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    if len(data) != asset["size"]:
        die(f"скачалось {len(data)} байт вместо {asset['size']}")

    print(f"  {len(data)} байт, sha256 {hashlib.sha256(data).hexdigest()}")
    signature = sign(data)
    print(f"  подпись: {signature}")

    # Версия для Sparkle - CFBundleVersion, он же сравнивает именно его.
    # Берём из Info.plist в рабочей копии: она соответствует тому тегу,
    # который собирали. Расхождение поймает проверка ниже.
    import plistlib
    plist = plistlib.load(open(
        pathlib.Path(__file__).resolve().parent.parent / "Resources/Info.plist", "rb"))
    short = plist["CFBundleShortVersionString"]
    build = plist["CFBundleVersion"]
    if tag.lstrip("v") != short:
        die(f"тег {tag} и версия в Info.plist ({short}) не совпадают - "
            f"подписал бы не то, что выпустил")

    item = {
        "title": f"Версия {short}",
        "short": short,
        "build": build,
        "url": url,
        "sig": signature,
        "length": str(len(data)),
        "date": format_datetime(datetime.now(timezone.utc)),
        "notes": rel.get("html_url", ""),
    }
    xml = build_feed(item)
    out = pathlib.Path(f"/tmp/{FEED_NAME}")
    out.write_text(xml)
    print(f"лента готова: {out}")
    print("проверь и запушь в ветку appcast:")
    print(f"  tools/push-appcast.sh {out}")


def build_feed(item: dict) -> str:
    """Одна запись в ленте, а не история.

    Sparkle берёт самую свежую подходящую, а старые записи нужны только для
    заметок о прошлых версиях - они и так есть на GitHub. Держать историю
    значит держать её в порядке, а порядок здесь никто не проверяет.
    """
    ET.register_namespace("sparkle", SPARKLE_NS)
    rss = ET.Element("rss", {"version": "2.0"})
    ch = ET.SubElement(rss, "channel")
    ET.SubElement(ch, "title").text = "climits"
    ET.SubElement(ch, "link").text = (
        f"https://raw.githubusercontent.com/{REPO}/{FEED_BRANCH}/{FEED_NAME}")
    ET.SubElement(ch, "description").text = "Обновления climits"
    ET.SubElement(ch, "language").text = "ru"

    it = ET.SubElement(ch, "item")
    ET.SubElement(it, "title").text = item["title"]
    ET.SubElement(it, "pubDate").text = item["date"]
    ET.SubElement(it, f"{{{SPARKLE_NS}}}version").text = item["build"]
    ET.SubElement(it, f"{{{SPARKLE_NS}}}shortVersionString").text = item["short"]
    ET.SubElement(it, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "13.0"
    if item["notes"]:
        ET.SubElement(it, "link").text = item["notes"]
    ET.SubElement(it, "enclosure", {
        "url": item["url"],
        "length": item["length"],
        "type": "application/octet-stream",
        f"{{{SPARKLE_NS}}}edSignature": item["sig"],
    })
    head = '<?xml version="1.0" encoding="utf-8"?>\n'
    return head + ET.tostring(rss, encoding="unicode") + "\n"


if __name__ == "__main__":
    main()
