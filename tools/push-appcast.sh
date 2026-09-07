#!/bin/bash
# Положить лету Sparkle в ветку appcast.
#
# Ветка-сирота, в ней один файл. Так адрес ленты остаётся коротким и
# постоянным, а история кода не тащится за файлом, который переписывается
# каждым релизом.
#
# СПОСОБ. Ветка собирается низкоуровневыми командами git, без клона и без
# переключения ветки в рабочей копии. Причины две, и обе кусали:
#   * переключение ветки в рабочей копии рискует несохранёнными правками;
#   * клон НЕ наследует локальный core.sshCommand, а пуш в этот репозиторий
#     идёт по отдельному deploy-ключу, прописанному именно в нём. Клон
#     пушить бы не смог, и понять почему было бы небыстро.
# hash-object/mktree/commit-tree работают в этом же репозитории, то есть
# с его настройками, и рабочего дерева не касаются вовсе.
#
# Отдельно от sign-release.py намеренно: подписать и опубликовать - разные
# действия. Между ними стоит человек, который смотрит на подпись глазами.
set -euo pipefail
cd "$(dirname "$0")/.."

FEED="${1:-/tmp/appcast.xml}"
[ -f "$FEED" ] || { echo "нет файла: $FEED" >&2; exit 1; }

# Проверки перед публикацией: без подписи лента бесполезна, а Sparkle
# скажет об этом невнятно и уже на машине человека.
grep -q 'sparkle:edSignature' "$FEED" || {
  echo "в ленте нет подписи - публиковать нечего" >&2; exit 1; }
grep -q 'sparkle:version' "$FEED" || {
  echo "в ленте нет sparkle:version - Sparkle сравнивает именно его" >&2; exit 1; }
python3 -c "import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])" "$FEED" || {
  echo "лента не разбирается как XML" >&2; exit 1; }

BLOB="$(git hash-object -w "$FEED")"
TREE="$(printf '100644 blob %s\tappcast.xml\n' "$BLOB" | git mktree)"
COMMIT="$(git commit-tree "$TREE" -m "лента обновлений")"
git push -f origin "$COMMIT:refs/heads/appcast"

echo "опубликовано:"
echo "  https://raw.githubusercontent.com/BabkoED/climits/appcast/appcast.xml"
echo
echo "raw кэширует минут пять и врёт свежестью - если Sparkle видит старое,"
echo "это кэш, а не ошибка публикации."
