#!/usr/bin/env bash
set -euo pipefail

# Byte-deterministic string comparison for the ISO-8601 slot timestamps below.
export LC_ALL=C

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

CONNECT_TIMEOUT=10
FETCH_MAX_TIME=30
BRR_MAX_TIME=20
NOTIFY_ATTEMPTS=3
RETRY_SLEEP=10

# How long the same class of error stays suppressed, and how many consecutive
# runs with no barber checked at all before we warn that we may be dead.
ERROR_COOLDOWN_SECONDS=21600  # 6 hours
FAILURE_ALERT_THRESHOLD=6     # ~3 hours of half-hourly runs

# Set by send_brr_notification to report whether the message actually landed.
BRR_LAST_OK=0

# Post a notification to Brrr. Never fatal — callers check BRR_LAST_OK to learn
# whether it arrived. Always returns 0 so that a notification failure can never
# abort the run and leave the remaining barbers unchecked.
send_brr_notification() {
  local title="$1"
  local message="$2"
  local payload attempt
  BRR_LAST_OK=0

  payload=$(jq -n \
    --arg title "$title" \
    --arg message "$message" \
    '{title: $title, message: $message}')

  for attempt in $(seq 1 "$NOTIFY_ATTEMPTS"); do
    # Never echo the URL: the secret key is a path segment of it.
    if curl -s --fail-with-body \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$BRR_MAX_TIME" \
        -X POST "https://api.brrr.now/v1/$BRR_SECRET_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload"; then
      BRR_LAST_OK=1
      return 0
    fi
    echo "Brrr notification attempt $attempt failed: $title" >&2
    if [[ "$attempt" -lt "$NOTIFY_ATTEMPTS" ]]; then sleep "$RETRY_SLEEP"; fi
  done

  echo "Warning: giving up on Brrr notification: $title" >&2
  return 0
}

# Send an error notification at most once per ERROR_COOLDOWN_SECONDS per key.
# The cooldown is stamped only once a message has actually been delivered, so an
# alert that never arrived cannot suppress the next attempt. Always returns 0.
notify_error() {
  local key="$1"
  local title="$2"
  local message="$3"
  local cooldown_file="${STATE_DIR}/cooldown_${key}.txt"
  local now last

  now=$(date +%s)
  last=$(cat "$cooldown_file" 2>/dev/null || echo 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0

  if [[ "$last" -gt 0 && $((now - last)) -lt "$ERROR_COOLDOWN_SECONDS" ]]; then
    echo "Suppressing '$key' alert: cooldown active, $(( (ERROR_COOLDOWN_SECONDS - (now - last)) / 60 ))m remaining."
    return 0
  fi

  send_brr_notification "$title" "$message"
  if [[ "$BRR_LAST_OK" == "1" ]]; then
    printf '%s\n' "$now" > "$cooldown_file"
  fi
  return 0
}

# Fetch availability from Acuity with retries. On success sets FETCH_BODY to the
# validated JSON body and returns 0. On failure sets FETCH_ERROR to a short
# reason and returns 1 — notifying is left to the caller so that a bad run
# reports one aggregated error rather than one per barber.
fetch_availability() {
  local url="$1"
  local label="$2"
  local MAX_ATTEMPTS=3
  local http_response http_body http_code
  FETCH_BODY=""
  FETCH_ERROR=""

  for attempt in $(seq 1 $MAX_ATTEMPTS); do
    http_response=$(curl -s -w "\n%{http_code}" \
      --connect-timeout "$CONNECT_TIMEOUT" --max-time "$FETCH_MAX_TIME" \
      -H "User-Agent: Mozilla/5.0 (compatible; barber-checker/1.0)" \
      "$url") || {
      echo "Attempt $attempt: curl failed"
      if [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; then sleep "$RETRY_SLEEP"; continue; fi
      FETCH_ERROR="curl request failed"
      return 1
    }

    http_body=$(echo "$http_response" | sed '$d')
    http_code=$(echo "$http_response" | tail -1)

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
      if ! echo "$http_body" | jq empty 2>/dev/null; then
        echo "Error: response is not valid JSON for $label"
        FETCH_ERROR="invalid JSON"
        return 1
      fi
      FETCH_BODY="$http_body"
      return 0
    fi

    echo "Attempt $attempt: API returned HTTP $http_code"
    if [[ "$attempt" -lt "$MAX_ATTEMPTS" ]]; then sleep "$RETRY_SLEEP"; continue; fi

    # A 403 is Acuity's bot-block and usually clears on its own, so it raises no
    # alert of its own. It still counts as a failed check, so a permanent one
    # trips the stalled-checker alert after the loop.
    if [[ "$http_code" -eq 403 ]]; then
      echo "Received 403 for $label after $MAX_ATTEMPTS attempts. Skipping silently."
      FETCH_ERROR="silent"
      return 1
    fi

    FETCH_ERROR="HTTP $http_code"
    return 1
  done
}

# Push the state commit, rebasing if a concurrent run got there first. Note that
# under rebase the ours/theirs labels invert: "theirs" is the commit being
# replayed, i.e. this run's state. Last writer wins, which is what we want.
push_state() {
  local attempt
  for attempt in 1 2 3; do
    if git push; then return 0; fi
    echo "Push rejected (attempt $attempt); rebasing onto origin/main..."
    if ! git pull --rebase -X theirs origin main; then
      git rebase --abort >/dev/null 2>&1 || true
      return 1
    fi
  done
  return 1
}

today=$(date +%Y-%m-%d)
echo "Checking availability from $today (7 days)..."

FAILURES=()
SILENT_FAILURES=0
SUCCESSES=0

for i in "${!BARBER_NAMES[@]}"; do
  name="${BARBER_NAMES[$i]}"
  calendar_id="${BARBER_CALENDAR_IDS[$i]}"
  appointment_type_id="${BARBER_APPOINTMENT_TYPE_IDS[$i]}"
  state_file="${STATE_DIR}/earliest_slot_${name,,}.txt"

  echo ""
  echo "--- Checking $name (calendarId: $calendar_id) ---"

  api_url="https://app.acuityscheduling.com/api/scheduling/v1/availability/times?owner=62aceac4&appointmentTypeId=${appointment_type_id}&calendarId=${calendar_id}&startDate=${today}&maxDays=7&timezone=Europe/London"

  if ! fetch_availability "$api_url" "$name"; then
    if [[ "$FETCH_ERROR" == "silent" ]]; then
      SILENT_FAILURES=$((SILENT_FAILURES + 1))
    else
      FAILURES+=("$name: $FETCH_ERROR")
    fi
    continue
  fi
  http_body="$FETCH_BODY"

  # jq empty above proves the body is valid JSON, not that it has the shape we
  # expect, so guard the extraction too rather than letting set -e kill the run.
  if ! total_slots=$(echo "$http_body" | jq '[.[] | length] | add // 0' 2>/dev/null); then
    echo "Error: unexpected response shape for $name"
    FAILURES+=("$name: unexpected response shape")
    continue
  fi

  if [[ "$total_slots" -eq 0 ]]; then
    echo "No availability found for $name."
    SUCCESSES=$((SUCCESSES + 1))
    echo "none" > "$state_file"
    continue
  fi

  echo "Found $total_slots slot(s) for $name!"

  if ! earliest=$(echo "$http_body" | jq -r '[.[] | .[].time] | sort | .[0]' 2>/dev/null) \
     || [[ -z "$earliest" || "$earliest" == "null" ]]; then
    echo "Error: could not read slot times for $name"
    FAILURES+=("$name: unexpected response shape")
    continue
  fi

  SUCCESSES=$((SUCCESSES + 1))

  earliest_date=$(echo "$earliest" | cut -dT -f1)
  earliest_time=$(echo "$earliest" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1 || true)
  earliest_formatted=$(date -d "$earliest_date" '+%a %d %b' 2>/dev/null || date -j -f "%Y-%m-%d" "$earliest_date" '+%a %d %b' 2>/dev/null || echo "$earliest_date")

  echo "  Earliest slot: $earliest_formatted at $earliest_time"

  stored=$(cat "$state_file" 2>/dev/null || echo "none")

  if [[ -z "$stored" || "$stored" == "none" || "$earliest" < "$stored" ]]; then
    echo "Earlier slot found for $name ($earliest vs stored: ${stored:-none}). Sending notification..."
    send_brr_notification "✂️ $name: $earliest_formatted at $earliest_time" "New earlier slot available — book now!"
    # Only advance the stored slot once the alert has actually been delivered,
    # otherwise a failed notification would silently retire the slot and you
    # would never be told about it.
    if [[ "$BRR_LAST_OK" == "1" ]]; then
      printf '%s\n' "$earliest" > "$state_file"
      echo "Done."
    else
      echo "Notification undelivered — leaving stored slot at '${stored:-none}' so the next run retries."
    fi
  else
    echo "No earlier slot for $name than $stored. Skipping notification."
    printf '%s\n' "$earliest" > "$state_file"
  fi
done

echo ""

# --- Failure reporting. Everything here writes to state/, so it must run before
# --- the commit block below or the cooldown stamps would be thrown away.
counter_file="${STATE_DIR}/consecutive_failures.txt"

if [[ "$SUCCESSES" -gt 0 ]]; then
  rm -f "$counter_file"
else
  consecutive=$(cat "$counter_file" 2>/dev/null || echo 0)
  [[ "$consecutive" =~ ^[0-9]+$ ]] || consecutive=0
  consecutive=$((consecutive + 1))
  printf '%s\n' "$consecutive" > "$counter_file"
  echo "No barber could be checked this run (consecutive failures: $consecutive)."
  if [[ "$consecutive" -ge "$FAILURE_ALERT_THRESHOLD" ]]; then
    notify_error "stalled" "Barber Checker Stalled" \
      "No successful check in $consecutive consecutive runs — the checker may be broken."
  fi
fi

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
  summary=$(printf '%s, ' "${FAILURES[@]}")
  summary="${summary%, }"
  echo "Failures this run: $summary"
  # Key on the set of error classes seen, so that a new kind of failure is never
  # masked by an unrelated cooldown that is already running.
  key=$(printf '%s\n' "${FAILURES[@]}" | sed 's/^.*: //' | sort -u | tr -cd '[:alnum:]')
  notify_error "${key:-unknown}" "Barber Checker Error" "Acuity checks failed — $summary"
fi

# Commit all state changes in a single push
git config user.email "github-actions[bot]@users.noreply.github.com"
git config user.name "github-actions[bot]"
git add "$STATE_DIR/"
if ! git diff --staged --quiet; then
  git commit -m "chore: update earliest slot state"
  push_state
fi
