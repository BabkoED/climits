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

# --- Sparkle: второй путь обновления -----------------------------------------
#
# Скачивается один раз в vendor/ и там остаётся: vendor/ ЗА пределами build/,
# который выше стирается целиком. Версия и сумма прибиты гвоздями - это
# чужой исполняемый код, который поедет внутри приложения, и «последняя
# доступная» тут означает «какая угодно, если однажды подменят релиз».
#
# Нет сети или сумма не сошлась - собираем БЕЗ Sparkle. Приложение от этого
# не ломается: обновление через GitHub-релизы работает как раньше, а код
# Sparkle спрятан за `#if canImport(Sparkle)`. Ронять сборку из-за второго
# пути обновления нельзя - первый важнее.
SPARKLE_VERSION="2.9.6"
SPARKLE_SHA="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
SPARKLE_FW="vendor/Sparkle.framework"
SPARKLE_FLAGS=()

fetch_sparkle() {
  [ -d "$SPARKLE_FW" ] && return 0
  command -v curl >/dev/null 2>&1 || return 1
  mkdir -p vendor
  local tgz="vendor/sparkle-$SPARKLE_VERSION.tar.xz"
  if [ ! -f "$tgz" ]; then
    curl -fsSL -o "$tgz" \
      "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
      || { rm -f "$tgz"; return 1; }
  fi
  local got
  got="$(shasum -a 256 "$tgz" | awk '{print $1}')"
  if [ "$got" != "$SPARKLE_SHA" ]; then
    echo "  Sparkle: сумма не сошлась, пропускаю" >&2
    echo "    ждали: $SPARKLE_SHA" >&2
    echo "    вышло: $got" >&2
    rm -f "$tgz"
    return 1
  fi
  tar -xJf "$tgz" -C vendor Sparkle.framework || return 1
  [ -d "$SPARKLE_FW" ]
}

if fetch_sparkle; then
  SPARKLE_FLAGS=(-F vendor -framework Sparkle
                 -Xlinker -rpath -Xlinker "@executable_path/../Frameworks")
  echo "  Sparkle $SPARKLE_VERSION на месте"
else
  echo "  Sparkle недоступен - собираю без второго пути обновления"
fi

# Собираем универсальный бинарник: в офисе почти наверняка есть и Apple
# Silicon, и Intel, а приложение под чужую архитектуру просто не запустится
# с невнятной ошибкой. SDK на macOS содержит обе, так что вторая сборка
# ничего не стоит. Если какая-то из них не вышла - не падаем, а честно
# сообщаем и отдаём то, что собралось.
SLICES=()
for arch in arm64 x86_64; do
  obj="$BUILD/climits-$arch"
  if swiftc -O -target "$arch-apple-macosx$MIN" \
       -framework AppKit -framework ServiceManagement -framework UserNotifications \
       ${SPARKLE_FLAGS[@]+"${SPARKLE_FLAGS[@]}"} \
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

# Фреймворк едет внутрь бандла: rpath выше указывает ровно сюда.
if [ "${#SPARKLE_FLAGS[@]}" -gt 0 ]; then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
fi

# Подпись ad-hoc. Без неё macOS относится к самосборному бандлу настороженно:
# автозапуск через SMAppService отказывает чаще, а при каждом обновлении
# сборки система заново спрашивает доступ к связке ключей.
#
# ПОРЯДОК ВАЖЕН: вложенный код подписывается ИЗНУТРИ НАРУЖУ, и только потом
# бандл. Ключа --deep здесь нет намеренно - дока Sparkle прямо запрещает его
# для своих служб. Порядок и набор путей взяты из разведочного прогона на
# macos-14, где эта последовательность прошла `codesign --verify --deep
# --strict`; сочинять её здесь нельзя, codesign на Linux не существует.
if command -v codesign >/dev/null 2>&1; then
  F="$APP/Contents/Frameworks/Sparkle.framework"
  for inner in \
    "$F/Versions/B/XPCServices/Installer.xpc" \
    "$F/Versions/B/XPCServices/Downloader.xpc" \
    "$F/Versions/B/Autoupdate" \
    "$F/Versions/B/Updater.app" \
    "$F"; do
    [ -e "$inner" ] && codesign -f -s - -o runtime "$inner" >/dev/null 2>&1
  done
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
