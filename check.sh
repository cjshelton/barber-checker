#!/usr/bin/env bash
set -euo pipefail

# Validate required env vars
if [[ -z "${BRR_SECRET_KEY:-}" ]]; then
  echo "Error: BRR_SECRET_KEY is not set"
  exit 1
fi

get_stored_slot() {
  curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
    "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/variables/EARLIEST_SLOT" \
    | jq -r '.value // empty'
}

set_stored_slot() {
  local value="$1"
  local api="https://api.github.com/repos/$GITHUB_REPOSITORY/actions/variables/EARLIEST_SLOT"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Content-Type: application/json" \
    "$api" -d "{\"name\":\"EARLIEST_SLOT\",\"value\":\"$value\"}")
  if [[ "$code" == "404" ]]; then
    curl -s -X POST \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.github.com/repos/$GITHUB_REPOSITORY/actions/variables" \
      -d "{\"name\":\"EARLIEST_SLOT\",\"value\":\"$value\"}" > /dev/null
  fi
}

send_brr_notification() {
  local title="$1"
  local message="$2"

  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg message "$message" \
    '{title: $title, message: $message}')

  curl -s --fail-with-body \
    -X POST "https://api.brrr.now/v1/$BRR_SECRET_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

# Build API URL
today=$(date +%Y-%m-%d)
api_url="https://app.acuityscheduling.com/api/scheduling/v1/availability/times?owner=62aceac4&appointmentTypeId=8321518&calendarId=2584005&startDate=${today}&maxDays=7&timezone=Europe/London"

echo "Checking availability from $today (7 days)..."

# Fetch availability
http_response=$(curl -s -w "\n%{http_code}" "$api_url") || {
  echo "Error: curl failed"
  send_brr_notification "Barber Checker Error" "curl request to Acuity API failed."
  exit 1
}

http_body=$(echo "$http_response" | sed '$d')
http_code=$(echo "$http_response" | tail -1)

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "Error: API returned HTTP $http_code"
  send_brr_notification "Barber Checker Error" "Acuity API returned HTTP $http_code."
  exit 1
fi

# Validate JSON
if ! echo "$http_body" | jq empty 2>/dev/null; then
  echo "Error: response is not valid JSON"
  send_brr_notification "Barber Checker Error" "Acuity API returned invalid JSON."
  exit 1
fi

# Check if any slots exist
total_slots=$(echo "$http_body" | jq '[.[] | length] | add // 0')

if [[ "$total_slots" -eq 0 ]]; then
  echo "No availability found."
  set_stored_slot "none"
  exit 0
fi

echo "Found $total_slots slot(s)!"

# Find earliest slot
earliest=$(echo "$http_body" | jq -r '[.[] | .[].time] | sort | .[0]')
earliest_date=$(echo "$earliest" | cut -dT -f1)
earliest_time=$(echo "$earliest" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1)
earliest_formatted=$(date -d "$earliest_date" '+%a %d %b' 2>/dev/null || date -j -f "%Y-%m-%d" "$earliest_date" '+%a %d %b' 2>/dev/null || echo "$earliest_date")

echo "  Earliest slot: $earliest_formatted at $earliest_time"

# Compare against stored earliest slot
stored=$(get_stored_slot)
set_stored_slot "$earliest"

if [[ -z "$stored" || "$stored" == "none" || "$earliest" < "$stored" ]]; then
  echo "Earlier slot found ($earliest vs stored: ${stored:-none}). Sending notification..."
  send_brr_notification "✂️ $earliest_formatted at $earliest_time" "New earlier slot available — book now!"
  echo "Done."
else
  echo "No earlier slot than $stored. Skipping notification."
fi
