#!/bin/bash
# Сборка climits.app одним вызовом swiftc, без Xcode-проекта.
#
# Нужны только Command Line Tools:  xcode-select --install
# Результат:  build/climits.app  - его можно просто перетащить в Applications.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="climits"
BUILD="build"
APP="$BUILD/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"

# Проверяем инструменты заранее и человеческим языком: «command not found:
# swiftc» ничего не говорит тому, кто просто хочет индикатор в трее.
if ! command -v swiftc >/dev/null 2>&1; then
  echo "Не найден swiftc. Поставь инструменты разработчика одной командой:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

# macOS 13 - минимум: SMAppService (автозапуск) появился именно там.
MIN="13.0"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=(Sources/*.swift)

# Собираем универсальный бинарник: в офисе почти наверняка есть и Apple
# Silicon, и Intel, а приложение под чужую архитектуру просто не запустится
# с невнятной ошибкой. SDK на macOS содержит обе, так что вторая сборка
# ничего не стоит. Если какая-то из них не вышла - не падаем, а честно
# сообщаем и отдаём то, что собралось.
SLICES=()
for arch in arm64 x86_64; do
  obj="$BUILD/climits-$arch"
  if swiftc -O -target "$arch-apple-macosx$MIN" \
       -framework AppKit -framework ServiceManagement \
       -o "$obj" "${SOURCES[@]}" 2>"$BUILD/$arch.log"; then
    SLICES+=("$obj")
    echo "  собрано: $arch"
  else
    echo "  пропущено: $arch (подробности в $BUILD/$arch.log)"
  fi
done

if [ "${#SLICES[@]}" -eq 0 ]; then
  echo "Сборка не удалась ни для одной архитектуры:" >&2
  cat "$BUILD"/*.log >&2
  exit 1
fi

if [ "${#SLICES[@]}" -gt 1 ] && command -v lipo >/dev/null 2>&1; then
  lipo -create -output "$BIN" "${SLICES[@]}"
  echo "  универсальный бинарник: $(lipo -archs "$BIN")"
else
  cp "${SLICES[0]}" "$BIN"
fi
rm -f "${SLICES[@]}"

cp Resources/Info.plist "$APP/Contents/Info.plist"

# Подпись ad-hoc. Без неё macOS относится к самосборному бандлу настороженно:
# автозапуск через SMAppService отказывает чаще, а при каждом обновлении
# сборки система заново спрашивает доступ к связке ключей.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP" >/dev/null 2>&1 \
    && echo "Подписано ad-hoc" \
    || echo "Подписать не удалось - приложение всё равно работает"
fi

echo
echo "Готово: $APP"
echo
echo "Дальше:"
echo "  cp -R $APP /Applications/          # или ~/Applications"
echo "  open /Applications/$APP_NAME.app   # иконка появится в строке меню"
echo
echo "Команда в терминале (по желанию):"
echo "  /Applications/$APP_NAME.app/Contents/MacOS/$APP_NAME --install-cli"
