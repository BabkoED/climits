#!/bin/bash
# Положить лету Sparkle в ветку appcast.
#
# Ветка-сирота, в ней один файл. Так сделано, чтобы адрес ленты был
# постоянным и коротким, и чтобы история кода не тащилась за файлом,
# который переписывается каждым релизом.
#
# Отдельно от sign-release.py намеренно: подписать и опубликовать - разные
# действия. Между ними стоит человек, который смотрит на подпись глазами.
# Пока схема на испытании, автоматизировать этот шаг рано.
set -euo pipefail
cd "$(dirname "$0")/.."

FEED="${1:-/tmp/appcast.xml}"
[ -f "$FEED" ] || { echo "нет файла: $FEED" >&2; exit 1; }

# Проверка перед публикацией: без подписи лента бесполезна, а Sparkle
# скажет об этом невнятно и уже на машине человека.
grep -q 'sparkle:edSignature' "$FEED" || {
  echo "в ленте нет подписи - публиковать нечего" >&2; exit 1; }
python3 -c "import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])" "$FEED" || {
  echo "лента не разбирается как XML" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$FEED" "$TMP/appcast.xml"

# Работаем в отдельном клоне: переключать ветки в рабочей копии значит
# рисковать несохранёнными правками.
git clone -q --no-checkout . "$TMP/repo"
cd "$TMP/repo"
git remote set-url origin "$(cd - >/dev/null && git remote get-url origin)"
git checkout -q --orphan appcast
git rm -rq --cached . 2>/dev/null || true
cp "$TMP/appcast.xml" appcast.xml
git add appcast.xml
git -c user.name="climits" -c user.email="climits@localhost" \
    commit -q -m "лента обновлений"
git push -f -q origin appcast

echo "опубликовано:"
echo "  https://raw.githubusercontent.com/BabkoED/climits/appcast/appcast.xml"
echo
echo "raw кэширует минут пять и врёт свежестью - если Sparkle видит старое,"
echo "это кэш, а не ошибка публикации."
