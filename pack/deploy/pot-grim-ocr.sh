#!/usr/bin/env bash
set -euo pipefail

mode=${1:?usage: pot-grim-ocr.sh <ocr|translate>}
case "$mode" in
  ocr) endpoint=ocr_recognize ;;
  translate) endpoint=ocr_translate ;;
  *) printf 'unknown mode: %s\n' "$mode" >&2; exit 2 ;;
esac

pot_cache=$HOME/.var/app/com.pot_app.pot/cache/com.pot-app.desktop
cut_path=$pot_cache/pot_screenshot_cut.png
mkdir -p "$pot_cache"
tmp_path=$(mktemp --suffix=.png)
trap 'rm -f "$tmp_path"' EXIT

geometry=$(slurp) || exit 0
grim -g "$geometry" "$tmp_path"
mv "$tmp_path" "$cut_path"

curl --silent --fail --max-time 5 \
  "http://127.0.0.1:60828/${endpoint}?screenshot=false" >/dev/null
