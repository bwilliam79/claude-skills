#!/bin/bash
# Statusline for Claude Code that also persists rate-limit reset timestamps
# for the session-auto-resume skill (~/.claude/skills/session-auto-resume).
#
# Claude Code pipes session JSON to this script on every statusline refresh.
# When the payload contains rate_limits (Pro/Max, after the first API response),
# the timestamps are written to ~/.claude/state/rate-limit-resets.json so any
# session can look up when the current 5-hour / 7-day windows reset.

input=$(cat)
STATE_DIR="$HOME/.claude/state"
STATE_FILE="$STATE_DIR/rate-limit-resets.json"
mkdir -p "$STATE_DIR"

# Persist rate-limit info when present (write tmp + mv so readers never see a partial file)
if echo "$input" | jq -e '.rate_limits' >/dev/null 2>&1; then
  echo "$input" | jq -c '{rate_limits: .rate_limits, updated_at: (now | floor)}' \
    > "$STATE_FILE.tmp" 2>/dev/null && mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

# --- Display ---
MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"')
EFFORT=$(echo "$input" | jq -r '.effort.level // empty')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""' | sed "s|^$HOME|~|")
CTX=$(echo "$input" | jq -r '.context_window.used_percentage // empty' | cut -d. -f1)
FIVE=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' | cut -d. -f1)
FIVE_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
WEEK=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | cut -d. -f1)
WEEK_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

GRAY=$'\033[90m'; CYAN=$'\033[36m'; LBLUE=$'\033[94m'; ROSE=$'\033[38;5;211m'; RST=$'\033[0m'
WHITE=$'\033[97m'
GRN=$'\033[32m'; YEL=$'\033[33m'; ORG=$'\033[38;5;208m'; XRED=$'\033[38;5;196m'
SEP="${GRAY} | ${RST}"

# Static hot ombré (dark red -> bright yellow-orange), stretched to fit
# whatever word it's coloring — no animation, no refreshInterval dependency.
OMBRE=(124 160 196 202 208 214 220)

ombre() {
  local text="$1" n=${#OMBRE[@]}
  local len=${#text}
  local denom=$(( len > 1 ? len - 1 : 1 ))
  local out="" i=0
  while [ $i -lt $len ]; do
    local idx=$(( i * (n - 1) / denom ))
    [ $idx -ge $n ] && idx=$((n - 1))
    out="${out}$(printf '\033[1;38;5;%sm' "${OMBRE[$idx]}")${text:$i:1}"
    i=$((i + 1))
  done
  printf '%s%s' "$out" "$RST"
}

# Heat gradient: green is good, yellow warning, orange dangerous, red at the limit
tint() {
  p=${1:-0}
  if   [ "$p" -ge 90 ]; then printf '%s' "$XRED"
  elif [ "$p" -ge 80 ]; then printf '%s' "$ORG"
  elif [ "$p" -ge 60 ]; then printf '%s' "$YEL"
  else                       printf '%s' "$GRN"
  fi
}

# Same gradient, keyed to effort level (cost proxy) instead of a percentage.
# max gets the ombré instead of a flat color — it's the loudest thing on the line.
effort_render() {
  case "$1" in
    low)    printf '%s%s%s' "$GRN" "$1" "$RST" ;;
    medium) printf '%s%s%s' "$YEL" "$1" "$RST" ;;
    high)   printf '%s%s%s' "$ORG" "$1" "$RST" ;;
    xhigh)  printf '%s%s%s' "$XRED" "$1" "$RST" ;;
    max)    ombre "$1" ;;
    *)      printf '%s%s%s' "$GRAY" "$1" "$RST" ;;
  esac
}

# Same gradient again, keyed to model tier (cheapest to priciest)
model_render() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *haiku*)            printf '%s%s%s' "$GRN" "$1" "$RST" ;;
    *sonnet*)           printf '%s%s%s' "$YEL" "$1" "$RST" ;;
    *opus*)             printf '%s%s%s' "$ORG" "$1" "$RST" ;;
    *fable*|*mythos*)   ombre "$1" ;;
    *)                  printf '%s%s%s' "$ROSE" "$1" "$RST" ;;
  esac
}

line="${WHITE}[ ${RST}$(model_render "$MODEL")"
[ -n "$EFFORT" ] && line="$line${WHITE} : ${RST}$(effort_render "$EFFORT")"
line="$line${WHITE} ]${RST}${SEP}${CYAN}${DIR}${RST}"
[ -n "$CTX" ] && line="$line${SEP}${WHITE}Context: ${RST}$(tint "$CTX")${CTX}%${RST}"
if [ -n "$FIVE" ]; then
  line="$line${SEP}${WHITE}5h Limit: ${RST}$(tint "$FIVE")${FIVE}%${RST}"
  if [ -n "$FIVE_RESET" ]; then
    RESET_FMT=$(date -r "$FIVE_RESET" "+%-I:%M%p" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    [ -n "$RESET_FMT" ] && line="$line ${GRAY}→${RST} ${LBLUE}${RESET_FMT}${RST}"
  fi
fi
if [ -n "$WEEK" ]; then
  line="$line${SEP}${WHITE}Weekly Limit: ${RST}$(tint "$WEEK")${WEEK}%${RST}"
  if [ -n "$WEEK_RESET" ]; then
    WEEK_RAW=$(date -r "$WEEK_RESET" "+%a %-I:%M%p" 2>/dev/null)
    [ -n "$WEEK_RAW" ] && WEEK_FMT="${WEEK_RAW%??}$(echo "${WEEK_RAW#"${WEEK_RAW%??}"}" | tr '[:upper:]' '[:lower:]')"
    [ -n "$WEEK_FMT" ] && line="$line ${GRAY}→${RST} ${LBLUE}${WEEK_FMT}${RST}"
  fi
fi

printf '%s\n' "$line"
