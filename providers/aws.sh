#!/bin/bash
# ponytail: $1 budget cap is a safety tripwire, not a real spend plan (this
# account has no promotional credit, actual monthly spend is ~$0.0006). The
# point is catching a forgotten instance, not tracking a prepaid balance.
set -uo pipefail
BUDGET_CAP=1.00
SIDE_PAD=2

# ponytail: left-aligned, not centered. A term_width()-based centering math
# doesn't always match what a small herdr pane actually renders, so
# short-suffix rows (e.g. "1.4%") got over-padded into wrapping.
left_line() {
  printf "%*s%b\n" "$SIDE_PAD" "" "$1"
}

# ponytail: bars fill as they approach the ceiling (spend toward the cap,
# quota toward the limit), the opposite direction of a "credit remaining"
# bar, because there's no prepaid balance here, just thresholds not to cross.
# ponytail: block-drawing chars (█/░) render double-width in narrow herdr
# panes, so an 8-block bar costs ~16 visual columns, not 8. Sized to still
# fit a ~45-col pane alongside a 10-char label and short suffix.
render_bar_used() {
  local label=$1 pct=$2 suffix=$3 width=8 filled color="\e[2;38;5;214m" dim="\e[2m" reset="\e[0m" alert="\e[1;31m" out=""
  local pct_i=${pct%.*}
  pct_i=${pct_i:-0}
  ((pct_i < 0)) && pct_i=0
  local over=$((pct_i > 100))
  ((pct_i > 100)) && pct_i=100
  filled=$(( (pct_i * width + 50) / 100 ))
  out+=$(printf "%-10.10s " "$label")
  out+=$(printf "%b" "$color")
  for ((i = 0; i < filled; i++)); do out+="█"; done
  out+=$(printf "%b" "$dim")
  for ((i = filled; i < width; i++)); do out+="░"; done
  out+=$(printf "%b %s" "$reset" "$suffix")
  ((over)) && out+=$(printf " %b⚠%b" "$alert" "$reset")
  left_line "$out"
}

expanded=false
account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

while true; do
  clear
  printf "%*sAWS · Budget\n" "$SIDE_PAD" ""
  echo

  # ponytail: Cost Explorer (ce get-cost-and-usage) costs $0.01/call, no free
  # tier. Switched to AWS Budgets (describe-budget), which is free for the
  # first 2 budgets/account, same ActualSpend data. Requires a budget named
  # herdr-freetier-bar with limit == BUDGET_CAP (create once, see README setup).
  resp=$(aws budgets describe-budget --account-id "$account_id" \
    --budget-name herdr-freetier-bar 2>&1)
  if [ $? -ne 0 ]; then
    left_line "$(printf '\e[2mnot authenticated: %s\e[0m' "$(sed -n '1p' <<<"$resp")")"
  else
    spend=$(jq -r '.Budget.CalculatedSpend.ActualSpend.Amount // "0"' <<<"$resp")
    pct=$(echo "scale=2; ($spend * 100) / $BUDGET_CAP" | bc)
    render_bar_used "spend" "$pct" "$(printf '$%.4f/$%.2f' "$spend" "$BUDGET_CAP")"
  fi

  echo
  printf "%*sAWS · Free Tier\n" "$SIDE_PAD" ""
  echo

  ft_resp=$(aws freetier get-free-tier-usage --max-results 100 2>&1)
  if [ $? -ne 0 ]; then
    left_line "$(printf '\e[2mnot authenticated: %s\e[0m' "$(sed -n '1p' <<<"$ft_resp")")"
  else
    # ponytail: 0.01% floor filters basal account noise (default alarms, idle
    # capacity) so the pane only shows what's worth tracking, not 8 rows of 0.0%.
    all=$(jq -c '[.freeTierUsages[]
      | select(.actualUsageAmount > 0 and .limit > 0)
      | . + {pct: (.actualUsageAmount / .limit * 100)}]
      | sort_by(-.pct)' <<<"$ft_resp" 2>/dev/null)
    if $expanded; then
      shown="$all"
    else
      shown=$(jq -c '[.[] | select(.pct > 0.01)]' <<<"${all:-[]}")
    fi
    count=$(jq 'length' <<<"${shown:-[]}" 2>/dev/null)
    total=$(jq 'length' <<<"${all:-[]}" 2>/dev/null)
    hidden=$((${total:-0} - ${count:-0}))
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
      left_line "$(printf '\e[2msin uso este mes\e[0m')"
    else
      while IFS=$'\t' read -r label pct; do
        if (($(echo "$pct < 0.01" | bc) )); then
          render_bar_used "$label" "$pct" "$(printf '%.4f%%' "$pct")"
        else
          render_bar_used "$label" "$pct" "$(printf '%.1f%%' "$pct")"
        fi
      done < <(jq -r '.[] | "\(.usageType)\t\(.pct)"' <<<"$shown")
    fi
    ((hidden > 0)) && left_line "$(printf '\e[2m+%d adicionales <0.01%%\e[0m' "$hidden")"
  fi

  echo
  left_line "$(printf '\e[2m%s  ·  q quit  ·  e expand  ·  r refresh\e[0m' "$(date +%H:%M)")"

  elapsed=0
  while ((elapsed < 1800)); do
    if read -rsn1 -t 1 key; then
      [[ "$key" == "q" ]] && exit 0
      [[ "$key" == "r" ]] && break
      if [[ "$key" == "e" ]]; then
        $expanded && expanded=false || expanded=true
        break
      fi
    fi
    elapsed=$((elapsed + 1))
  done
done
