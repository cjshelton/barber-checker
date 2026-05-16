#!/usr/bin/env bash
set -euo pipefail

# Validate required env vars
if [[ -z "${BRR_SECRET_KEY:-}" ]]; then
  echo "Error: BRR_SECRET_KEY is not set"
  exit 1
fi

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
  exit 0
fi

echo "Found $total_slots slot(s)!"

# Format notification message
notification_message=""

while IFS= read -r date_key; do
  # Format date nicely (e.g. "Tue 25 Feb")
  formatted_date=$(date -d "$date_key" '+%a %d %b' 2>/dev/null || date -j -f "%Y-%m-%d" "$date_key" '+%a %d %b' 2>/dev/null || echo "$date_key")

  # Get times for this date
  times=$(echo "$http_body" | jq -r --arg d "$date_key" '.[$d][] | .time' | while IFS= read -r t; do
    # Extract HH:MM from ISO timestamp
    echo "$t" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1
  done | paste -sd ', ' -)

  if [[ -n "$times" ]]; then
    notification_message+="$formatted_date: $times"$'\n'
    echo "  $formatted_date: $times"
  fi
done < <(echo "$http_body" | jq -r 'keys[]')

notification_message+="https://app.acuityscheduling.com/schedule.php?owner=62aceac4&appointmentType=8321518"

# Send notification
echo "Sending Brr notification..."
send_brr_notification "Barber slot available!" "$notification_message"
echo "Done."
