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

OUT="$(mktemp -d)/climits-tests"
trap 'rm -rf "$(dirname "$OUT")"' EXIT

swiftc -swift-version 5 -o "$OUT" \
  Sources/L10n.swift \
  Sources/UsageModel.swift \
  Sources/Prefs.swift \
  Sources/Format.swift \
  Sources/Pricing.swift \
  Sources/Transcripts.swift \
  Tests/main.swift

"$OUT"
