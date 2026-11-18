#!/usr/bin/env bash
# Optionaler Helfer, um die Splitwise-API direkt per curl zu erkunden.
# Für den Betrieb der Extension nicht nötig.
#
#   cp .env.example .env   und SPLITWISE_API_KEY eintragen
#   ./explore.sh get_current_user
#   ./explore.sh get_friends
#   ./explore.sh 'get_expenses?limit=5'

set -euo pipefail

cd "$(dirname "$0")"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${SPLITWISE_API_KEY:?SPLITWISE_API_KEY fehlt — .env anlegen (siehe .env.example)}"

ENDPOINT="${1:-get_current_user}"

curl -sS -w '\nHTTP %{http_code}\n' \
  -H "Authorization: Bearer ${SPLITWISE_API_KEY}" \
  -H 'Accept: application/json' \
  "https://secure.splitwise.com/api/v3.0/${ENDPOINT}"
