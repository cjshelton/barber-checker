#!/usr/bin/env bash
set -euo pipefail

# Validate required env vars
if [[ -z "${BRR_SECRET_KEY:-}" ]]; then
  echo "Error: BRR_SECRET_KEY is not set"
  exit 1
fi

STATE_DIR="state"
mkdir -p "$STATE_DIR"

# Barber definitions — parallel arrays of name, calendarId, and appointmentTypeId
BARBER_NAMES=("Charlie" "James" "Hali")
BARBER_CALENDAR_IDS=("2584005" "2583998" "5678927")
BARBER_APPOINTMENT_TYPE_IDS=("8321518" "8321518" "23895699")

# Specific date we always watch for cancellations, regardless of the earliest
# slot found in the rolling 7-day window. Set to empty to disable.
TARGET_DATE="2026-08-10"

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

# Fetch availability from Acuity with retries. On success, sets FETCH_BODY to the
# validated JSON body and returns 0. On failure, notifies (except silent 403s)
# and returns 1.
fetch_availability() {
  local url="$1"
  local label="$2"
  local MAX_ATTEMPTS=3
  local http_response http_body http_code
  FETCH_BODY=""

  for attempt in $(seq 1 $MAX_ATTEMPTS); do
    http_response=$(curl -s -w "\n%{http_code}" \
      -H "User-Agent: Mozilla/5.0 (compatible; barber-checker/1.0)" \
      "$url") || {
      echo "Attempt $attempt: curl failed"
      if [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; then sleep 10; continue; fi
      send_brr_notification "Barber Checker Error" "curl request failed for $label."
      return 1
    }

    http_body=$(echo "$http_response" | sed '$d')
    http_code=$(echo "$http_response" | tail -1)

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
      if ! echo "$http_body" | jq empty 2>/dev/null; then
        echo "Error: response is not valid JSON for $label"
        send_brr_notification "Barber Checker Error" "Acuity API returned invalid JSON for $label."
        return 1
      fi
      FETCH_BODY="$http_body"
      return 0
    fi

    echo "Attempt $attempt: API returned HTTP $http_code"
    if [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; then sleep 10; continue; fi

    if [[ "$http_code" -eq 403 ]]; then
      echo "Received 403 for $label after $MAX_ATTEMPTS attempts. Skipping silently."
      return 1
    fi

    send_brr_notification "Barber Checker Error" "Acuity API returned HTTP $http_code for $label."
    return 1
  done
}

today=$(date +%Y-%m-%d)
echo "Checking availability from $today (7 days)..."

for i in "${!BARBER_NAMES[@]}"; do
  name="${BARBER_NAMES[$i]}"
  calendar_id="${BARBER_CALENDAR_IDS[$i]}"
  appointment_type_id="${BARBER_APPOINTMENT_TYPE_IDS[$i]}"
  state_file="${STATE_DIR}/earliest_slot_${name,,}.txt"

  echo ""
  echo "--- Checking $name (calendarId: $calendar_id) ---"

  api_url="https://app.acuityscheduling.com/api/scheduling/v1/availability/times?owner=62aceac4&appointmentTypeId=${appointment_type_id}&calendarId=${calendar_id}&startDate=${today}&maxDays=7&timezone=Europe/London"

  if ! fetch_availability "$api_url" "$name"; then continue; fi
  http_body="$FETCH_BODY"

  total_slots=$(echo "$http_body" | jq '[.[] | length] | add // 0')

  if [[ "$total_slots" -eq 0 ]]; then
    echo "No availability found for $name."
    echo "none" > "$state_file"
    continue
  fi

  echo "Found $total_slots slot(s) for $name!"

  earliest=$(echo "$http_body" | jq -r '[.[] | .[].time] | sort | .[0]')
  earliest_date=$(echo "$earliest" | cut -dT -f1)
  earliest_time=$(echo "$earliest" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1)
  earliest_formatted=$(date -d "$earliest_date" '+%a %d %b' 2>/dev/null || date -j -f "%Y-%m-%d" "$earliest_date" '+%a %d %b' 2>/dev/null || echo "$earliest_date")

  echo "  Earliest slot: $earliest_formatted at $earliest_time"

  stored=$(cat "$state_file" 2>/dev/null || echo "none")
  echo "$earliest" > "$state_file"

  if [[ -z "$stored" || "$stored" == "none" || "$earliest" < "$stored" ]]; then
    echo "Earlier slot found for $name ($earliest vs stored: ${stored:-none}). Sending notification..."
    send_brr_notification "✂️ $name: $earliest_formatted at $earliest_time" "New earlier slot available — book now!"
    echo "Done."
  else
    echo "No earlier slot for $name than $stored. Skipping notification."
  fi

  # --- Cancellation watch for a specific target date ---
  # The rolling window above only reports the *earliest* slot, so a cancellation
  # on a later target date (e.g. after an existing earlier slot) is never seen.
  # Fetch that single date separately and notify on any newly-available slot.
  if [[ -z "$TARGET_DATE" ]]; then continue; fi

  echo ""
  echo "--- Checking $name for cancellations on $TARGET_DATE ---"

  target_url="https://app.acuityscheduling.com/api/scheduling/v1/availability/times?owner=62aceac4&appointmentTypeId=${appointment_type_id}&calendarId=${calendar_id}&startDate=${TARGET_DATE}&maxDays=1&timezone=Europe/London"

  if ! fetch_availability "$target_url" "$name ($TARGET_DATE)"; then continue; fi

  target_state_file="${STATE_DIR}/target_slots_${name,,}.txt"
  current_times=$(echo "$FETCH_BODY" | jq -r '[.[] | .[].time] | .[]' 2>/dev/null \
    | grep -oE '[0-9]{2}:[0-9]{2}' | sort -u || true)
  stored_times=$(cat "$target_state_file" 2>/dev/null || true)

  # Slots available now that weren't available on the previous run (cancellations).
  new_times=$(comm -23 <(printf '%s\n' "$current_times") <(printf '%s\n' "$stored_times") || true)

  printf '%s\n' "$current_times" > "$target_state_file"

  if [[ -n "${current_times//[[:space:]]/}" ]]; then
    echo "  Slots on $TARGET_DATE: $(printf '%s' "$current_times" | paste -sd, -)"
  else
    echo "  No slots on $TARGET_DATE."
  fi

  if [[ -n "${new_times//[[:space:]]/}" ]]; then
    times_list=$(printf '%s' "$new_times" | paste -sd, -)
    target_formatted=$(date -d "$TARGET_DATE" '+%a %d %b' 2>/dev/null || date -j -f "%Y-%m-%d" "$TARGET_DATE" '+%a %d %b' 2>/dev/null || echo "$TARGET_DATE")
    echo "New slot(s) on $TARGET_DATE for $name: $times_list. Sending notification..."
    send_brr_notification "✂️ $name: cancellation on $target_formatted!" "New slot(s) at $times_list — book now!"
  else
    echo "No new slots on $TARGET_DATE for $name. Skipping notification."
  fi
done

# Commit all state changes in a single push
git config user.email "github-actions[bot]@users.noreply.github.com"
git config user.name "github-actions[bot]"
git add "$STATE_DIR/"
if ! git diff --staged --quiet; then
  git commit -m "chore: update earliest slot state"
  git push
fi
