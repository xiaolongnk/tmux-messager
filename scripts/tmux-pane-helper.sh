#!/usr/bin/env bash
# Inventory and resolve tmux panes inside a named window (tab).
# Terminology: tmux "window" = tab; "pane" = split inside that window.
# When running inside tmux (TMUX set), default: exclude the invoking pane from
# resolve candidates if it is in the same session+window as the target.
set -euo pipefail

INCLUDE_SELF=0
while [[ "${1:-}" == "--include-self" ]]; do
  INCLUDE_SELF=1
  shift
done

_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tmux-cursor-submit-resolve.sh
source "${_HELPER_DIR}/tmux-cursor-submit-resolve.sh"

usage() {
  cat <<'EOF'
Usage:
  tmux-pane-helper.sh [--include-self] inventory <session> <window>
  tmux-pane-helper.sh [--include-self] resolve  <session> <window> <selector>
  tmux-pane-helper.sh client
  tmux-pane-helper.sh active-pane <session> <window>
  tmux-pane-helper.sh find-kw-session <session> <keyword>
                    (stdout: session:window.pane for tmux -t; inside tmux excludes client pane)
  tmux-pane-helper.sh find-kw-session-all <session> <keyword>
                    (stdout: one session:window.pane per line for ALL matches)
  tmux-pane-helper.sh find-kw-window <session> <keyword>
                    (stdout: window_index 0,1,2… status-bar tab; same scan as find-kw-session)
  tmux-pane-helper.sh [--include-self] send [send-options] <session> <window> <selector> <message...>

  Send options (Cursor TUI defaults: tmux-cursor-submit-resolve.sh; Ghostty/Darwin → kitty-enter):
    --shell              end with C-m (shell / REPL line)
    --ctrl-enter         end with C-Enter (tmux named key)
    --kitty-enter        end with ESC [ 13 u (Cursor Agent submit in Ghostty+tmux — default)
    --kitty-c-enter      end with ESC [ 13 ; 5 u (often newline in Cursor; legacy)
    --kitty-ctrl4        end with ESC [ 13 ; 4 u
    --kitty-alt2         end with ESC [ 13 ; 2 u
    --shift-enter        end with S-Enter
    --meta-enter         end with M-Enter
    --ctrl-shift-enter   end with C-S-Enter
    --ctrl-meta-enter    end with C-M-Enter

  --include-self   Do not exclude the tmux client pane (default: exclude self
                   when client is in the same session+window as <window>).

<window> may be window index (e.g. 5), window name, or **.** = current window (#I).

  client          — (inside tmux only) print current client session / window / pane
                    and send-keys target for the client's window. Do NOT use this target
                    to message a *different* pane — it points at THIS pane.
  active-pane     — print pane_index of the focused pane in the given window
                    (#{pane_active}; the pane that would receive keys in that window).
  send            — resolve <selector> (excluding self by default), then tmux send-keys.
                    Default ends with C-Enter (Ctrl+Enter) for Cursor Agent; use --shell for C-m (REPL).

Selectors for resolve:
  active | focused                          — pane with keyboard focus in that window (not self-excluded)
  first | second | third | fourth | fifth     — reading order (top→down, then left→right)
  nth-N                                     — Nth in that order (e.g. nth-2 = second)
  left | right                              — min / max pane_left (tie: smaller top wins)
  top | bottom                              — min / max pane_top (tie: smaller left wins)
  left-top | left-bottom                    — within column(s) at min pane_left: min/max top
  right-top | right-bottom                  — within column(s) at max pane_left: min/max top
  index-N                                   — explicit tmux pane_index (NOT excluded; must exist)
  title:TEXT                                — pane whose #{pane_title} contains TEXT (case-insensitive)
  kw:TEXT | match:TEXT                      — keyword in pane_title OR pane_current_command OR
                                              capture-pane scrollback (see find-kw-session for all windows)

Examples:
  S="$(tmux display-message -p '#S')"
  ./.claude/skills/tmux/scripts/tmux-pane-helper.sh inventory "$S" .
  ./.claude/skills/tmux/scripts/tmux-pane-helper.sh resolve "$S" . second
  ./.claude/skills/tmux/scripts/tmux-pane-helper.sh send "$S" . first hello
  ./.claude/skills/tmux/scripts/tmux-pane-helper.sh send --ctrl-enter "$S" . first hello
  ./.claude/skills/tmux/scripts/tmux-pane-helper.sh resolve "$S" . kw:claude
  ./.claude/skills/tmux/scripts/tmux-pane-helper.sh find-kw-session "$S" claude
  WI=$(./.claude/skills/tmux/scripts/tmux-pane-helper.sh find-kw-window "$S" claude); tmux select-window -t "$S:$WI"
  W="$(tmux display-message -p '#I')"
  TARGET=$(./.claude/skills/tmux/scripts/tmux-pane-helper.sh resolve "$S" . left-top)
  tmux send-keys -t "$S:$W.$TARGET" 'hello' S-Enter
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
CMD="$1"
shift || true

# Prints pane_index to stdout when the tmux client is attached to the same
# session and window as target session:window; else exit 1.
# Focused pane in window (pane_active=1). Prints pane_index or empty.
active_pane_index_in_window() {
  local session="$1" window="$2"
  tmux list-panes -t "$session:$window" -F '#{pane_index} #{pane_active}' 2>/dev/null \
    | awk '$2 == 1 { print $1; exit }'
}

get_self_pane_index_in_target_window() {
  local session="$1" window="$2"
  [[ -n "${TMUX:-}" ]] || return 1
  local cs cw cp tw
  cs=$(tmux display-message -p '#{session_name}' 2>/dev/null) || return 1
  cw=$(tmux display-message -p '#{window_index}' 2>/dev/null) || return 1
  cp=$(tmux display-message -p '#{pane_index}' 2>/dev/null) || return 1
  tw=$(tmux display-message -t "$session:$window" -p '#{window_index}' 2>/dev/null) || return 1
  [[ "$cs" == "$session" ]] || return 1
  [[ "$cw" == "$tw" ]] || return 1
  printf '%s\n' "$cp"
  return 0
}

# Run inside tmux: where this client is attached (current window = window with focus for this client).
client_info() {
  [[ -n "${TMUX:-}" ]] || { echo "error: not inside tmux (TMUX unset)" >&2; return 1; }
  local s wi wn p ap
  s=$(tmux display-message -p '#{session_name}' 2>/dev/null) || { echo "error: tmux display-message failed" >&2; return 1; }
  wi=$(tmux display-message -p '#{window_index}' 2>/dev/null) || return 1
  wn=$(tmux display-message -p '#{window_name}' 2>/dev/null) || wn="?"
  p=$(tmux display-message -p '#{pane_index}' 2>/dev/null) || return 1
  ap=$(active_pane_index_in_window "$s" "$wi")
  echo "session=$s window_index=$wi window_name=$wn pane_index=$p"
  echo "active_pane_in_this_window=${ap:-?}"
  echo "target=${s}:${wn}.${p}"
  echo "target_by_index=${s}:${wi}.${p}"
}

print_client_line() {
  [[ -n "${TMUX:-}" ]] || return 0
  local cs cw cp wn
  cs=$(tmux display-message -p '#{session_name}' 2>/dev/null) || return 0
  cw=$(tmux display-message -p '#{window_index}' 2>/dev/null) || return 0
  cp=$(tmux display-message -p '#{pane_index}' 2>/dev/null) || return 0
  wn=$(tmux display-message -p '#{window_name}' 2>/dev/null) || wn="?"
  echo "client=${cs}:${cw}(${wn}).${cp}"
  if [[ "$INCLUDE_SELF" -eq 0 ]]; then
    echo "resolve_excludes_client_pane_in_this_window=yes  (pass --include-self to disable)"
  else
    echo "resolve_excludes_client_pane_in_this_window=no (--include-self)"
  fi
}

# Window arg "." = current client's window index (#{window_index}). No hard-coded tab names.
expand_window_dot() {
  local window="$1"
  if [[ "$window" != . ]]; then
    printf '%s\n' "$window"
    return 0
  fi
  [[ -n "${TMUX:-}" ]] || { echo "error: window '.' requires TMUX (run inside tmux)" >&2; return 1; }
  tmux display-message -p '#I' 2>/dev/null || { echo "error: tmux display-message #I failed" >&2; return 1; }
}

inventory() {
  local session="$1" window="$2"
  window=$(expand_window_dot "$window") || return 1
  print_client_line
  echo ""

  local n
  n=$(tmux list-panes -t "$session:$window" 2>/dev/null | wc -l | tr -d ' ')
  echo "session=$session window=$window pane_count=$n"
  echo ""

  local excl=""
  if [[ "$INCLUDE_SELF" -eq 0 ]] && excl=$(get_self_pane_index_in_target_window "$session" "$window" 2>/dev/null); then
    :
  else
    excl=""
  fi

  local ap_idx
  ap_idx=$(active_pane_index_in_window "$session" "$window")

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    idx left top w h self active title command path
  while IFS=$'\t' read -r idx left top w h pact title cmd path; do
    local mark="" am=""
    [[ -n "$excl" && "$idx" == "$excl" ]] && mark='*'
    [[ "$pact" == "1" ]] && am='*'
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$idx" "$left" "$top" "$w" "$h" "$mark" "$am" "$title" "$cmd" "$path"
  done < <(tmux list-panes -t "$session:$window" -F \
    '#{pane_index}	#{pane_left}	#{pane_top}	#{pane_width}	#{pane_height}	#{pane_active}	#{pane_title}	#{pane_current_command}	#{pane_current_path}')

  echo ""
  echo "active_pane_index_in_this_window=${ap_idx:-?}  (column active * = keyboard focus in this window)"

  echo ""
  echo "Derived labels (self column * = this tmux client pane, excluded from resolve unless --include-self):"
  local tmp cand
  tmp=$(mktemp)
  tmux list-panes -t "$session:$window" -F '#{pane_index} #{pane_left} #{pane_top}' >"$tmp"
  cand=$(mktemp)
  if [[ -n "$excl" ]]; then
    awk -v ex="$excl" '$1 != ex {print}' "$tmp" >"$cand"
  else
    cp "$tmp" "$cand"
  fi
  echo "  reading_order (top→down, then left→right) — use: first | second | nth-N"
  if [[ -s "$cand" ]]; then
    sort -k3,3n -k2,2n "$cand" | awk '{print "    " NR " -> pane_index " $1 " (left=" $2 " top=" $3 ")"}'
  else
    echo "    (no candidate panes after excluding self)"
  fi
  echo "  geometry hints — use: left-top | left-bottom | right-top | right-bottom | left | right | top | bottom"
  awk '
    { idx[NR]=$1; L[$1]=$2+0; T[$1]=$3+0; n=NR }
    END {
      if (n<1) exit
      minl=maxl=L[idx[1]]; mint=maxt=T[idx[1]]
      for (i=1;i<=n;i++) {
        id=idx[i]
        if (L[id]<minl) minl=L[id]
        if (L[id]>maxl) maxl=L[id]
        if (T[id]<mint) mint=T[id]
        if (T[id]>maxt) maxt=T[id]
      }
      for (i=1;i<=n;i++) {
        id=idx[i]
        printf "    pane %s: left=%d top=%d", id, L[id], T[id]
        if (L[id]==minl) printf " [min-left]"
        if (L[id]==maxl) printf " [max-left]"
        if (T[id]==mint) printf " [min-top]"
        if (T[id]==maxt) printf " [max-top]"
        print ""
      }
    }
  ' "$tmp"
  rm -f "$tmp" "$cand"
}

# Scan all windows in session; exclude only the invoking client's pane (same as resolve self-exclude).
# Stdout: one target line "session:window_name.pane_index" for tmux -t. Stderr: how it matched.
find_kw_session() {
  local session="$1" keyword="$2"
  [[ -n "$keyword" ]] || { echo "error: empty keyword" >&2; return 1; }

  local csw cwi cpi wi wn idx t c
  csw=""; cwi=""; cpi=""
  if [[ -n "${TMUX:-}" ]]; then
    csw=$(tmux display-message -p '#{session_name}' 2>/dev/null) || true
    cwi=$(tmux display-message -p '#{window_index}' 2>/dev/null) || true
    cpi=$(tmux display-message -p '#{pane_index}' 2>/dev/null) || true
  fi

  while IFS=$'\t' read -r wi wn; do
    while IFS= read -r idx; do
      [[ "$csw" == "$session" && "$wi" == "$cwi" && "$idx" == "$cpi" ]] && continue
      t=$(tmux display-message -t "$session:${wi}.${idx}" -p '#{pane_title}' 2>/dev/null) || continue
      c=$(tmux display-message -t "$session:${wi}.${idx}" -p '#{pane_current_command}' 2>/dev/null) || continue
      if printf '%s\n%s\n' "$t" "$c" | grep -qiF "$keyword"; then
        echo "match=title_or_command window=${wi}(${wn}) pane=${idx}" >&2
        printf '%s:%s.%s\n' "$session" "$wn" "$idx"
        return 0
      fi
    done < <(tmux list-panes -t "$session:$wi" -F '#{pane_index}' 2>/dev/null)
  done < <(tmux list-windows -t "$session" -F '#{window_index}	#{window_name}' 2>/dev/null)

  while IFS=$'\t' read -r wi wn; do
    while IFS= read -r idx; do
      [[ "$csw" == "$session" && "$wi" == "$cwi" && "$idx" == "$cpi" ]] && continue
      if tmux capture-pane -t "$session:${wi}.${idx}" -p -S -8000 2>/dev/null | grep -qiF "$keyword"; then
        echo "match=capture window=${wi}(${wn}) pane=${idx}" >&2
        printf '%s:%s.%s\n' "$session" "$wn" "$idx"
        return 0
      fi
    done < <(tmux list-panes -t "$session:$wi" -F '#{pane_index}' 2>/dev/null)
  done < <(tmux list-windows -t "$session" -F '#{window_index}	#{window_name}' 2>/dev/null)

  echo "error: no pane in session '$session' matched keyword: $keyword" >&2
  return 1
}

# Like find-kw-session but returns ALL matching panes, one per line.
# Stdout: "session:window_name.pane_index" per match. Stderr: match details.
# Returns 0 if at least one match found, 1 otherwise.
find_kw_session_all() {
  local session="$1" keyword="$2"
  [[ -n "$keyword" ]] || { echo "error: empty keyword" >&2; return 1; }

  local csw cwi cpi wi wn idx t c found=0
  csw=""; cwi=""; cpi=""
  if [[ -n "${TMUX:-}" ]]; then
    csw=$(tmux display-message -p '#{session_name}' 2>/dev/null) || true
    cwi=$(tmux display-message -p '#{window_index}' 2>/dev/null) || true
    cpi=$(tmux display-message -p '#{pane_index}' 2>/dev/null) || true
  fi

  while IFS=$'\t' read -r wi wn; do
    while IFS= read -r idx; do
      [[ "$csw" == "$session" && "$wi" == "$cwi" && "$idx" == "$cpi" ]] && continue
      t=$(tmux display-message -t "$session:${wi}.${idx}" -p '#{pane_title}' 2>/dev/null) || continue
      c=$(tmux display-message -t "$session:${wi}.${idx}" -p '#{pane_current_command}' 2>/dev/null) || continue
      if printf '%s\n%s\n' "$t" "$c" | grep -qiF "$keyword"; then
        echo "match=title_or_command window=${wi}(${wn}) pane=${idx}" >&2
        printf '%s:%s.%s\n' "$session" "$wn" "$idx"
        found=1
      fi
    done < <(tmux list-panes -t "$session:$wi" -F '#{pane_index}' 2>/dev/null)
  done < <(tmux list-windows -t "$session" -F '#{window_index}	#{window_name}' 2>/dev/null)

  while IFS=$'\t' read -r wi wn; do
    while IFS= read -r idx; do
      [[ "$csw" == "$session" && "$wi" == "$cwi" && "$idx" == "$cpi" ]] && continue
      if tmux capture-pane -t "$session:${wi}.${idx}" -p -S -8000 2>/dev/null | grep -qiF "$keyword"; then
        echo "match=capture window=${wi}(${wn}) pane=${idx}" >&2
        printf '%s:%s.%s\n' "$session" "$wn" "$idx"
        found=1
      fi
    done < <(tmux list-panes -t "$session:$wi" -F '#{pane_index}' 2>/dev/null)
  done < <(tmux list-windows -t "$session" -F '#{window_index}	#{window_name}' 2>/dev/null)

  [[ "$found" -eq 1 ]] || {
    echo "error: no pane in session '$session' matched keyword: $keyword" >&2
    return 1
  }
  return 0
}

# First tmux *window* (tab index in status bar) where any pane matches keyword.
# Stdout: window_index only (e.g. 5). Stderr: window_name, pane, match type.
find_kw_window() {
  local session="$1" keyword="$2"
  [[ -n "$keyword" ]] || { echo "error: empty keyword" >&2; return 1; }

  local csw cwi cpi wi wn idx t c
  csw=""; cwi=""; cpi=""
  if [[ -n "${TMUX:-}" ]]; then
    csw=$(tmux display-message -p '#{session_name}' 2>/dev/null) || true
    cwi=$(tmux display-message -p '#{window_index}' 2>/dev/null) || true
    cpi=$(tmux display-message -p '#{pane_index}' 2>/dev/null) || true
  fi

  while IFS=$'\t' read -r wi wn; do
    while IFS= read -r idx; do
      [[ "$csw" == "$session" && "$wi" == "$cwi" && "$idx" == "$cpi" ]] && continue
      t=$(tmux display-message -t "$session:${wi}.${idx}" -p '#{pane_title}' 2>/dev/null) || continue
      c=$(tmux display-message -t "$session:${wi}.${idx}" -p '#{pane_current_command}' 2>/dev/null) || continue
      if printf '%s\n%s\n' "$t" "$c" | grep -qiF "$keyword"; then
        echo "match=title_or_command window_index=${wi} window_name=${wn} pane=${idx}" >&2
        printf '%s\n' "$wi"
        return 0
      fi
    done < <(tmux list-panes -t "$session:$wi" -F '#{pane_index}' 2>/dev/null)
  done < <(tmux list-windows -t "$session" -F '#{window_index}	#{window_name}' 2>/dev/null)

  while IFS=$'\t' read -r wi wn; do
    while IFS= read -r idx; do
      [[ "$csw" == "$session" && "$wi" == "$cwi" && "$idx" == "$cpi" ]] && continue
      if tmux capture-pane -t "$session:${wi}.${idx}" -p -S -8000 2>/dev/null | grep -qiF "$keyword"; then
        echo "match=capture window_index=${wi} window_name=${wn} pane=${idx}" >&2
        printf '%s\n' "$wi"
        return 0
      fi
    done < <(tmux list-panes -t "$session:$wi" -F '#{pane_index}' 2>/dev/null)
  done < <(tmux list-windows -t "$session" -F '#{window_index}	#{window_name}' 2>/dev/null)

  echo "error: no window in session '$session' matched keyword: $keyword" >&2
  return 1
}

# shellcheck disable=SC2310
resolve_one() {
  local session="$1" window="$2" sel="$3"
  window=$(expand_window_dot "$window") || return 1

  case "$sel" in
    active|focused)
      local ap
      ap=$(active_pane_index_in_window "$session" "$window")
      [[ -n "$ap" ]] || { echo "error: could not find active pane in $session:$window" >&2; return 1; }
      printf '%s\n' "$ap"
      return 0
      ;;
  esac

  local exclude=""
  if [[ "$sel" != index-* ]] && [[ "$INCLUDE_SELF" -eq 0 ]]; then
    exclude=$(get_self_pane_index_in_target_window "$session" "$window" 2>/dev/null || true)
  fi

  case "$sel" in
    kw:* | match:*)
      local kw
      if [[ "$sel" == match:* ]]; then
        kw="${sel#match:}"
      else
        kw="${sel#kw:}"
      fi
      [[ -n "$kw" ]] || { echo "error: empty keyword (use kw:word or match:word)" >&2; return 1; }
      local idx picked="" how=""
      while IFS= read -r idx; do
        [[ -n "$exclude" && "$idx" == "$exclude" ]] && continue
        local t c
        t=$(tmux display-message -t "$session:${window}.${idx}" -p '#{pane_title}' 2>/dev/null) || continue
        c=$(tmux display-message -t "$session:${window}.${idx}" -p '#{pane_current_command}' 2>/dev/null) || continue
        if printf '%s\n%s\n' "$t" "$c" | grep -qiF "$kw"; then
          picked=$idx
          how="title_or_command"
          break
        fi
      done < <(tmux list-panes -t "$session:$window" -F '#{pane_index}' 2>/dev/null)

      if [[ -z "$picked" ]]; then
        while IFS= read -r idx; do
          [[ -n "$exclude" && "$idx" == "$exclude" ]] && continue
          if tmux capture-pane -t "$session:${window}.${idx}" -p -S -8000 2>/dev/null | grep -qiF "$kw"; then
            picked=$idx
            how=capture
            break
          fi
        done < <(tmux list-panes -t "$session:$window" -F '#{pane_index}' 2>/dev/null)
      fi

      [[ -n "$picked" ]] || { echo "error: kw: no pane matched '$kw' in $session:$window (after excluding self)" >&2; return 1; }
      echo "match=${how} keyword=${kw} pane=${picked}" >&2
      printf '%s\n' "$picked"
      return 0
      ;;
  esac

  local alltmp tmp
  alltmp=$(mktemp)
  if ! tmux list-panes -t "$session:$window" -F '#{pane_index} #{pane_left} #{pane_top}' >"$alltmp" 2>/dev/null; then
    echo "error: no panes for $session:$window" >&2
    rm -f "$alltmp"
    return 1
  fi

  case "$sel" in
    index-*)
      tmp="$alltmp"
      alltmp=""
      ;;
    title:*)
      rm -f "$alltmp"
      alltmp=""
      local needle="${sel#title:}"
      [[ -n "$needle" ]] || { echo "error: empty title: pattern" >&2; return 1; }
      local tfile picked
      tfile=$(mktemp)
      if ! tmux list-panes -t "$session:$window" -F '#{pane_index}	#{pane_title}' >"$tfile" 2>/dev/null; then
        echo "error: list-panes failed" >&2
        rm -f "$tfile"
        return 1
      fi
      if [[ -n "$exclude" ]]; then
        awk -F'	' -v ex="$exclude" -v OFS='	' '$1 != ex { print }' "$tfile" >"${tfile}.f"
        mv "${tfile}.f" "$tfile"
      fi
      picked=$(awk -F'	' -v n="$needle" 'index(tolower($2), tolower(n)) > 0 { print $1; exit }' "$tfile")
      rm -f "$tfile"
      [[ -n "$picked" ]] || { echo "error: no pane title match for: $needle (after excluding self)" >&2; return 1; }
      echo "$picked"
      return 0
      ;;
    *)
      tmp=$(mktemp)
      if [[ -n "$exclude" ]]; then
        awk -v ex="$exclude" '$1 != ex {print}' "$alltmp" >"$tmp"
      else
        cp "$alltmp" "$tmp"
      fi
      rm -f "$alltmp"
      alltmp=""
      if [[ ! -s "$tmp" ]]; then
        echo "error: no candidate panes after excluding self (use --include-self or another window)" >&2
        rm -f "$tmp"
        return 1
      fi
      ;;
  esac

  reading_nth() {
    local k="$1"
    sort -k3,3n -k2,2n "$tmp" | awk -v k="$k" 'NR==k {print $1; exit}'
  }

  local out=""
  case "$sel" in
    first|nth-1) out=$(reading_nth 1) ;;
    second|nth-2) out=$(reading_nth 2) ;;
    third|nth-3) out=$(reading_nth 3) ;;
    fourth|nth-4) out=$(reading_nth 4) ;;
    fifth|nth-5) out=$(reading_nth 5) ;;
    nth-*)
      local k="${sel#nth-}"
      [[ "$k" =~ ^[0-9]+$ ]] || { echo "bad nth" >&2; rm -f "$tmp"; return 1; }
      out=$(reading_nth "$k")
      ;;
    index-*)
      local k="${sel#index-}"
      [[ "$k" =~ ^[0-9]+$ ]] || { echo "bad index" >&2; rm -f "$tmp"; return 1; }
      if ! grep -q "^${k} " "$tmp"; then
        echo "error: pane_index $k not in window" >&2
        rm -f "$tmp"
        return 1
      fi
      out="$k"
      ;;
    left)
      out=$(sort -k2,2n -k3,3n "$tmp" | head -1 | awk '{print $1}')
      ;;
    right)
      out=$(sort -k2,2nr -k3,3n "$tmp" | head -1 | awk '{print $1}')
      ;;
    top)
      out=$(sort -k3,3n -k2,2n "$tmp" | head -1 | awk '{print $1}')
      ;;
    bottom)
      out=$(sort -k3,3nr -k2,2n "$tmp" | head -1 | awk '{print $1}')
      ;;
    left-top)
      out=$(awk '
        { idx[NR]=$1; L[$1]=$2+0; T[$1]=$3+0; n=NR }
        END {
          minl=999999
          for (i=1;i<=n;i++) { id=idx[i]; if (L[id]<minl) minl=L[id] }
          mint=999999; pick=""
          for (i=1;i<=n;i++) {
            id=idx[i]
            if (L[id]==minl && T[id]<mint) { mint=T[id]; pick=id }
          }
          print pick
        }
      ' "$tmp")
      ;;
    left-bottom)
      out=$(awk '
        { idx[NR]=$1; L[$1]=$2+0; T[$1]=$3+0; n=NR }
        END {
          minl=999999
          for (i=1;i<=n;i++) { id=idx[i]; if (L[id]<minl) minl=L[id] }
          maxt=-1; pick=""
          for (i=1;i<=n;i++) {
            id=idx[i]
            if (L[id]==minl && T[id]>maxt) { maxt=T[id]; pick=id }
          }
          print pick
        }
      ' "$tmp")
      ;;
    right-top)
      out=$(awk '
        { idx[NR]=$1; L[$1]=$2+0; T[$1]=$3+0; n=NR }
        END {
          maxl=-1
          for (i=1;i<=n;i++) { id=idx[i]; if (L[id]>maxl) maxl=L[id] }
          mint=999999; pick=""
          for (i=1;i<=n;i++) {
            id=idx[i]
            if (L[id]==maxl && T[id]<mint) { mint=T[id]; pick=id }
          }
          print pick
        }
      ' "$tmp")
      ;;
    right-bottom)
      out=$(awk '
        { idx[NR]=$1; L[$1]=$2+0; T[$1]=$3+0; n=NR }
        END {
          maxl=-1
          for (i=1;i<=n;i++) { id=idx[i]; if (L[id]>maxl) maxl=L[id] }
          maxt=-1; pick=""
          for (i=1;i<=n;i++) {
            id=idx[i]
            if (L[id]==maxl && T[id]>maxt) { maxt=T[id]; pick=id }
          }
          print pick
        }
      ' "$tmp")
      ;;
    *)
      echo "error: unknown selector '$sel'" >&2
      rm -f "$tmp"
      return 1
      ;;
  esac

  rm -f "$tmp"
  [[ -n "$out" ]] || { echo "error: empty resolve result (not enough panes after exclude?)" >&2; return 1; }
  printf '%s\n' "$out"
}

# Resolve selector (honours INCLUDE_SELF), then send-keys.
# Cursor Agent in tmux: S-Enter often does not submit; defaults from tmux-cursor-submit-resolve.sh.
send_message() {
  local use_shell=0
  local submit
  submit="$(resolve_tmux_cursor_submit)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --shell)
        use_shell=1
        shift
        ;;
      --shift-enter | --s-enter)
        submit="s-enter"
        shift
        ;;
      --ctrl-enter | --c-enter)
        submit="c-enter"
        shift
        ;;
      --kitty-c-enter)
        submit="kitty-c-enter"
        shift
        ;;
      --kitty-enter)
        submit="kitty-enter"
        shift
        ;;
      --kitty-ctrl4)
        submit="kitty-ctrl4"
        shift
        ;;
      --kitty-alt2)
        submit="kitty-alt2"
        shift
        ;;
      --meta-enter | --m-enter)
        submit="m-enter"
        shift
        ;;
      --ctrl-shift-enter | --cs-enter)
        submit="cs-enter"
        shift
        ;;
      --ctrl-meta-enter | --cm-enter)
        submit="cm-enter"
        shift
        ;;
      *)
        break
        ;;
    esac
  done
  [[ $# -ge 4 ]] || usage
  local session window sel p
  session="$1"
  window="$2"
  sel="$3"
  shift 3
  window=$(expand_window_dot "$window") || return 1
  local text="$*"
  [[ -n "$text" ]] || { echo "error: empty message" >&2; return 1; }
  p=$(resolve_one "$session" "$window" "$sel") || return 1
  echo "send-keys -> ${session}:${window}.${p} submit=${submit}" >&2
  if [[ "$use_shell" -eq 1 ]]; then
    tmux send-keys -t "${session}:${window}.${p}" "$text" C-m
    return 0
  fi
  case "$submit" in
    s-enter) tmux send-keys -t "${session}:${window}.${p}" "$text" S-Enter ;;
    c-enter) tmux send-keys -t "${session}:${window}.${p}" "$text" C-Enter ;;
    m-enter) tmux send-keys -t "${session}:${window}.${p}" "$text" M-Enter ;;
    cs-enter) tmux send-keys -t "${session}:${window}.${p}" "$text" C-S-Enter ;;
    cm-enter) tmux send-keys -t "${session}:${window}.${p}" "$text" C-M-Enter ;;
    kitty-c-enter)
      tmux send-keys -t "${session}:${window}.${p}" "$text"
      tmux send-keys -t "${session}:${window}.${p}" $'\e[13;5u'
      ;;
    kitty-enter)
      tmux send-keys -t "${session}:${window}.${p}" "$text"
      tmux send-keys -t "${session}:${window}.${p}" $'\e[13u'
      ;;
    kitty-ctrl4)
      tmux send-keys -t "${session}:${window}.${p}" "$text"
      tmux send-keys -t "${session}:${window}.${p}" $'\e[13;4u'
      ;;
    kitty-alt2)
      tmux send-keys -t "${session}:${window}.${p}" "$text"
      tmux send-keys -t "${session}:${window}.${p}" $'\e[13;2u'
      ;;
    *)
      echo "error: internal submit=$submit" >&2
      return 1
      ;;
  esac
}

case "$CMD" in
  inventory)
    [[ $# -eq 2 ]] || usage
    inventory "$1" "$2"
    ;;
  resolve)
    [[ $# -eq 3 ]] || usage
    out=$(resolve_one "$1" "$2" "$3") || exit 1
    [[ -n "$out" ]] || { echo "error: empty resolve result" >&2; exit 1; }
    printf '%s\n' "$out"
    ;;
  client)
    [[ $# -eq 0 ]] || usage
    client_info
    ;;
  active-pane)
    [[ $# -eq 2 ]] || usage
    win=$(expand_window_dot "$2") || exit 1
    out=$(active_pane_index_in_window "$1" "$win")
    [[ -n "$out" ]] || { echo "error: no active pane in $1:$2" >&2; exit 1; }
    printf '%s\n' "$out"
    ;;
  send)
    [[ $# -ge 4 ]] || usage
    send_message "$@" || exit 1
    ;;
  find-kw-session)
    [[ $# -eq 2 ]] || usage
    find_kw_session "$1" "$2" || exit 1
    ;;
  find-kw-session-all)
    [[ $# -eq 2 ]] || usage
    find_kw_session_all "$1" "$2" || exit 1
    ;;
  find-kw-window)
    [[ $# -eq 2 ]] || usage
    find_kw_window "$1" "$2" || exit 1
    ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
