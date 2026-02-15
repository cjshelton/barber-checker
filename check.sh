#!/usr/bin/env bash
set -euo pipefail

# Validate required env vars
for var in RESEND_API_KEY EMAIL_TO EMAIL_FROM; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: $var is not set"
    exit 1
  fi
done

send_email() {
  local subject="$1"
  local body="$2"

  local payload
  payload=$(jq -n \
    --arg to "$EMAIL_TO" \
    --arg from "$EMAIL_FROM" \
    --arg subject "$subject" \
    --arg body "$body" \
    '{
      from: $from,
      to: $to,
      subject: $subject,
      html: $body
    }')

  curl -s --fail-with-body \
    -X POST "https://api.resend.com/emails" \
    -H "Authorization: Bearer $RESEND_API_KEY" \
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
  send_email "Barber Checker Error" "<p>curl request to Acuity API failed.</p>"
  exit 1
}

http_body=$(echo "$http_response" | sed '$d')
http_code=$(echo "$http_response" | tail -1)

if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
  echo "Error: API returned HTTP $http_code"
  send_email "Barber Checker Error" "<p>Acuity API returned HTTP $http_code.</p><pre>$http_body</pre>"
  exit 1
fi

# Validate JSON
if ! echo "$http_body" | jq empty 2>/dev/null; then
  echo "Error: response is not valid JSON"
  send_email "Barber Checker Error" "<p>Acuity API returned invalid JSON.</p>"
  exit 1
fi

# Check if any slots exist
total_slots=$(echo "$http_body" | jq '[.[] | length] | add // 0')

if [[ "$total_slots" -eq 0 ]]; then
  echo "No availability found."
  exit 0
fi

echo "Found $total_slots slot(s)!"

# Format email body
email_body="<h2>Barber availability found!</h2><ul>"

while IFS= read -r date_key; do
  # Format date nicely (e.g. "Tue 25 Feb")
  formatted_date=$(date -d "$date_key" '+%a %d %b' 2>/dev/null || date -j -f "%Y-%m-%d" "$date_key" '+%a %d %b' 2>/dev/null || echo "$date_key")

  # Get times for this date
  times=$(echo "$http_body" | jq -r --arg d "$date_key" '.[$d][] | .time' | while IFS= read -r t; do
    # Extract HH:MM from ISO timestamp
    echo "$t" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1
  done | paste -sd ', ' -)

  if [[ -n "$times" ]]; then
    email_body+="<li><strong>$formatted_date</strong>: $times</li>"
    echo "  $formatted_date: $times"
  fi
done < <(echo "$http_body" | jq -r 'keys[]')

email_body+="</ul><p><a href=\"https://app.acuityscheduling.com/schedule.php?owner=62aceac4&appointmentType=8321518\">Book now</a></p>"

# Send notification
echo "Sending email to $EMAIL_TO..."
send_email "Barber slot available!" "$email_body"
echo "Done."
