#!/usr/bin/env bash
set -euo pipefail

# Remove FluidAudio's LuxTTS English G2P data from a built app. FluidAudio's
# TTS trait links it into every build, but the lexicon and aux tables are
# espeak-ng derived (GPL-3.0-or-later, word keys CC-BY-SA-4.0). Osaurus never
# runs LuxTTS, and FluidAudio's ThirdPartyLicenses/LuxTtsEnglishG2P-LICENSE.md
# lets apps that don't use it leave the data out. Run before the app is
# signed: removing a sealed resource afterwards breaks the signature.
#
# Usage: strip_luxtts_g2p.sh <App>.app

APP="${1:?usage: strip_luxtts_g2p.sh <App>.app}"
if [[ ! -d "$APP/Contents" ]]; then
  echo "not an app bundle: $APP" >&2
  exit 64
fi

find "$APP/Contents" -name '*LuxTts*' -prune -print -exec rm -rf {} +

# A renamed bundle would otherwise ship unnoticed.
remaining="$(find "$APP/Contents" -iname '*luxtts*' -print)"
if [[ -n "$remaining" ]]; then
  echo "LuxTTS data still in the app:" >&2
  echo "$remaining" >&2
  exit 65
fi
