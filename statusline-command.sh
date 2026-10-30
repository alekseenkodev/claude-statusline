#!/bin/bash
# Claude Code statusline.
# Two lines:
#   📁 ~/path/dir | 🌿 [branch] +added/-removed
#   🤖 model effort | <emoji> <context bar> tokens/budget | $cost | 5h:% ↻reset 7d:% ↻reset
# Each field has its own color; metrics go green/yellow/red by threshold,
# the context bar is a truecolor green -> yellow -> red gradient.

input=$(cat)

# Skip optional git locks (status-line runs shouldn't contend with other git ops)
export GIT_OPTIONAL_LOCKS=0

# --- colors ---
C_RESET=$'\033[0m'
C_PATH=$'\033[01;34m'     # bold blue
C_MODEL=$'\033[01;35m'    # bold magenta
C_DIM=$'\033[90m'         # grey
C_BRANCH=$'\033[36m'      # cyan
C_ADD=$'\033[92m'         # bright green
C_DEL=$'\033[91m'         # bright red
C_COST=$'\033[33m'        # yellow
C_SEP=$'\033[90m'         # dark grey separators
C_OK=$'\033[32m'          # green
C_WARN=$'\033[01;33m'     # bold yellow
C_CRIT=$'\033[01;31m'     # bold red
C_EMPTY=$'\033[38;2;60;60;60m'  # dark grey for empty bar blocks

BAR_WIDTH=20

# Truecolor foreground escape
rgb() {
  printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"
}

# Traffic-light color for a percentage: green < 50, yellow < 80, red otherwise
level_color() {
  if [ "$1" -ge 80 ]; then
    printf '%s' "$C_CRIT"
  elif [ "$1" -ge 50 ]; then
    printf '%s' "$C_WARN"
  else
    printf '%s' "$C_OK"
  fi
}

round() {
  awk -v v="$1" 'BEGIN{printf "%d", v+0.5}'
}

# --- cwd (raw, before ~ substitution — used for the git lookup too) ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd=$(pwd)
display_cwd="${cwd/#$HOME/\~}"
path_cell="📁 ${C_PATH}${display_cwd}${C_RESET}"

# --- model: bold magenta display name, plus grey effort level when present ---
model=$(echo "$input" | jq -r '.model.display_name // "?"' 2>/dev/null)
effort=$(echo "$input" | jq -r '.effort.level // empty' 2>/dev/null)
model_cell="🤖 ${C_MODEL}${model}${C_RESET}"
[ -n "$effort" ] && model_cell="$model_cell ${C_DIM}${effort}${C_RESET}"

# --- git_branch: current branch, else short HEAD (detached), else "-" when not a git repo ---
branch=$(cd "$cwd" 2>/dev/null && git branch --show-current 2>/dev/null)
if [ -z "$branch" ]; then
  branch=$(cd "$cwd" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null)
fi
[ -z "$branch" ] && branch="-"

# --- branch display: [branch] as an OSC 8 hyperlink to the repo's branch page
# when the repo fields are available and the branch is known; plain [branch]
# (or [-]) otherwise ---
repo_host=$(echo "$input" | jq -r '.workspace.repo.host // empty' 2>/dev/null)
repo_owner=$(echo "$input" | jq -r '.workspace.repo.owner // empty' 2>/dev/null)
repo_name=$(echo "$input" | jq -r '.workspace.repo.name // empty' 2>/dev/null)
if [ -n "$repo_host" ] && [ -n "$repo_owner" ] && [ -n "$repo_name" ] && [ "$branch" != "-" ]; then
  branch_url="https://$repo_host/$repo_owner/$repo_name/tree/$branch"
  branch_disp=$(printf '\033]8;;%s\033\\%s[%s]%s\033]8;;\033\\' "$branch_url" "$C_BRANCH" "$branch" "$C_RESET")
else
  branch_disp="${C_BRANCH}[$branch]${C_RESET}"
fi

# --- lines changed: +<added>/-<removed>, appended to the branch cell; omitted if both missing ---
lines_added=$(echo "$input" | jq -r '.cost.total_lines_added // empty' 2>/dev/null)
lines_removed=$(echo "$input" | jq -r '.cost.total_lines_removed // empty' 2>/dev/null)
branch_cell="🌿 $branch_disp"
if [ -n "$lines_added" ] || [ -n "$lines_removed" ]; then
  branch_cell="$branch_cell ${C_ADD}+${lines_added:-0}${C_RESET}${C_DIM}/${C_RESET}${C_DEL}-${lines_removed:-0}${C_RESET}"
fi

# --- total tokens used so far: prefer summing separate input/output (+cache)
# fields when present, else fall back to whatever total field exists ---
total_tokens=$(echo "$input" | jq -r '
  if (.context_window.current_usage != null)
  then ((.context_window.current_usage.input_tokens // 0)
        + (.context_window.current_usage.output_tokens // 0)
        + (.context_window.current_usage.cache_creation_input_tokens // 0)
        + (.context_window.current_usage.cache_read_input_tokens // 0))
  elif (.context_window.total_input_tokens != null or .context_window.total_output_tokens != null)
  then ((.context_window.total_input_tokens // 0) + (.context_window.total_output_tokens // 0))
  else empty
  end
' 2>/dev/null)

if [ -z "$total_tokens" ]; then
  token_str="?k"
else
  token_str=$(awk -v t="$total_tokens" 'BEGIN{
    if (t < 1000) { printf "%d", t; exit }
    k = t / 1000
    r = int(k + 0.5)
    if (r < 1000) { printf "%dk", r; exit }
    printf "%.1fM", k / 1000
  }')
fi

# --- context: <emoji> <20-block gradient bar> <tokens>/<budget>. Measured against
# CTX_BUDGET, the point where answer quality degrades in practice, not against the
# full model window (1M). Each filled block takes the gradient color of its
# position, so the bar reddens as it fills; emoji and token color follow absolute
# thresholds: green < 100k, yellow < 250k, red < 400k, alarm from 400k ---
CTX_BUDGET=450000
CTX_WARN=100000
CTX_HIGH=250000
CTX_ALARM=400000

ctx_tokens="$total_tokens"
if [ -z "$ctx_tokens" ]; then
  # Fall back to percentage of the full window when token fields are missing
  ctx_tokens=$(echo "$input" | jq -r '
    if (.context_window.used_percentage != null and .context_window.context_window_size != null)
    then (.context_window.used_percentage * .context_window.context_window_size / 100 | floor)
    else empty
    end
  ' 2>/dev/null)
fi

if [ -n "$ctx_tokens" ]; then
  filled=$(( (ctx_tokens * BAR_WIDTH + CTX_BUDGET / 2) / CTX_BUDGET ))
  [ "$filled" -gt "$BAR_WIDTH" ] && filled=$BAR_WIDTH
  bar=""
  for (( i=0; i<BAR_WIDTH; i++ )); do
    if [ "$i" -lt "$filled" ]; then
      pos=$(( i * 100 / (BAR_WIDTH - 1) ))
      if [ "$pos" -le 50 ]; then
        r=$(( 220 * pos / 50 )); g=200; b=$(( 80 - 80 * pos / 50 ))
      else
        adj=$(( pos - 50 ))
        r=220; g=$(( 200 - 160 * adj / 50 )); b=$(( 20 * adj / 50 ))
      fi
      bar="${bar}$(rgb $r $g $b)█"
    else
      bar="${bar}${C_EMPTY}░"
    fi
  done
  bar="${bar}${C_RESET}"

  if [ "$ctx_tokens" -ge "$CTX_ALARM" ]; then ctx_emoji="🚨"; ctx_color=$'\033[01;91m'
  elif [ "$ctx_tokens" -ge "$CTX_HIGH" ]; then ctx_emoji="🔥"; ctx_color=$'\033[31m'
  elif [ "$ctx_tokens" -ge "$CTX_WARN" ]; then ctx_emoji="⚡"; ctx_color="$C_WARN"
  else ctx_emoji="🟢"; ctx_color="$C_OK"; fi

  [ -z "$total_tokens" ] && token_str="~$(( ctx_tokens / 1000 ))k"
  token_cell="${ctx_emoji} ${bar} ${ctx_color}${token_str}${C_RESET}${C_DIM}/$(( CTX_BUDGET / 1000 ))k${C_RESET}"
else
  token_cell="${C_DIM}${token_str}${C_RESET}"
fi

# --- session cost: $<total>, two decimals, yellow; omitted if field missing ---
cost_usd=$(echo "$input" | jq -r '.cost.total_cost_usd // empty' 2>/dev/null)
cost_str=""
if [ -n "$cost_usd" ]; then
  cost_str="${C_COST}$(awk -v c="$cost_usd" 'BEGIN{printf "$%.2f", c}')${C_RESET}"
fi

# --- rate limits: 5h:<n>% ↻HH:MM (in XhYm)  7d:<m>% ↻Day HH:MM, traffic-light colored,
# reset time in grey (local timezone); omitted if both missing ---
now=$(date +%s)
rate_str=""
for spec in "five_hour:5h:%H:%M" "seven_day:7d:%a %H:%M"; do
  key="${spec%%:*}"
  rest="${spec#*:}"
  label="${rest%%:*}"
  reset_fmt="${rest#*:}"
  pct=$(echo "$input" | jq -r ".rate_limits.$key.used_percentage // empty" 2>/dev/null)
  [ -z "$pct" ] && continue
  pct_int=$(round "$pct")
  seg="${C_DIM}${label}:${C_RESET}$(level_color "$pct_int")${pct_int}%${C_RESET}"

  resets_at=$(echo "$input" | jq -r ".rate_limits.$key.resets_at // empty" 2>/dev/null)
  if [ -n "$resets_at" ] && [ "$resets_at" -gt "$now" ] 2>/dev/null; then
    reset_str="↻$(LC_ALL=C date -d "@$resets_at" +"$reset_fmt" 2>/dev/null || LC_ALL=C date -r "$resets_at" +"$reset_fmt")"
    if [ "$key" = "five_hour" ]; then
      left=$(( resets_at - now ))
      reset_str="$reset_str ($(( left / 3600 ))h$(( left % 3600 / 60 ))m)"
    fi
    seg="$seg ${C_DIM}${reset_str}${C_RESET}"
  fi
  rate_str="${rate_str:+$rate_str  }$seg"
done

sep=" ${C_SEP}|${C_RESET} "
line1="${path_cell}${sep}${branch_cell}"
line2="${model_cell}${sep}${token_cell}"
for seg in "$cost_str" "$rate_str"; do
  [ -n "$seg" ] && line2="${line2}${sep}${seg}"
done

printf '%s\n%s' "$line1" "$line2"
