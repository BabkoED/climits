#!/bin/bash
# Проверки логики: разбор ответа API, единицы денег, сборка строки меню.
#
# Ни AppKit, ни Security, ни сети здесь нет - поэтому гоняется где угодно,
# где есть swiftc,
# включая Linux и CI. Это те места, где ошибка не видна глазами: сумма,
# завышенная в сто раз, выглядит ровно так же убедительно, как правильная.
set -euo pipefail
cd "$(dirname "$0")"

command -v swiftc >/dev/null 2>&1 || { echo "нет swiftc" >&2; exit 1; }

# Сверка имён ДО сборки тестов.
#
# Половина исходников тянет AppKit и на Linux не типизируется вовсе -
# значит переименование поля в них ловит только CI. Эта проверка ловит
# тот же класс ошибки за секунду и без macOS. Поймано ею же 12.09.2026:
# настройку переименовали, одно обращение осталось, снимок меню упал.
python3 tools/check-refs.py

# Питон, который уезжает по ssh на удалённую машину, - на подставных файлах.
# До 1.21.0 его не проверял никто: Swift видит только разбор его ответа,
# а две тихие ошибки в нём нашлись ревью 09.10.2026 только прогоном.
python3 tools/check-remote-script.py

OUT="$(mktemp -d)/climits-tests"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

swiftc -swift-version 5 -o "$OUT" \
  Sources/L10n.swift \
  Sources/UsageModel.swift \
  Sources/Prefs.swift \
  Sources/NotifyRules.swift \
  Sources/Format.swift \
  Sources/Keychain.swift \
  Sources/Presets.swift \
  Sources/Pricing.swift \
  Sources/PricingFeed.swift \
  Sources/Transcripts.swift \
  Sources/Sessions.swift \
  Sources/SessionWatch.swift \
  Sources/History.swift \
  Sources/Version.swift \
  Sources/RemoteScan.swift \
  Sources/ServiceStatus.swift \
  Sources/ServiceStatusFetch.swift \
  Sources/AdaptiveRefresh.swift \
  Sources/Pace.swift \
  Sources/CodexUsage.swift \
  Tests/main.swift

"$OUT"
