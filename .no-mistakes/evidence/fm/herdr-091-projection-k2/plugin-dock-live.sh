#!/usr/bin/env bash
# Live driver: real fm-spawn.sh / fm-teardown.sh against a guarded fm-lab-*
# Herdr 0.9.1 session in an ISOLATED throwaway Herdr home (HOME/XDG_CONFIG_HOME
# under /tmp) whose only plugin is a copy of herdr-sidebar 0.13.0, enabled.
# The operator's real Herdr home, its default session, and its plugin state are
# never addressed.
# Usage: plugin-dock-live.sh <worktree-root> <isolated-home>
set -u
ROOT=$1
H=$2
export HOME=$H XDG_CONFIG_HOME=$H/.config
unset HERDR_BIN_PATH HERDR_STARTUP_CWD HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
export FM_GATE_REFUSE_BYPASS=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
ORIG_PATH=$PATH
REAL_HERDR=$(command -v herdr)
HELPER=$ROOT/bin/fm-herdr-lab.sh
W=$(mktemp -d /tmp/fmtest-pd.XXXX)
FAKEBIN=$W/bin
mkdir -p "$FAKEBIN"
LAB=$("$HELPER" name plugdock)
export ORIG_PATH REAL_HERDR HELPER
export HERDR_LAB_SESSION=$LAB

FAILS=0
say() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS + 1)); }
lab() { PATH="$ORIG_PATH" "$HELPER" run "$LAB" "$@"; }

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n - 2))]}" = --session ] && [ "${args[$((n - 1))]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$((n - 1))]" "args[$((n - 2))]"
fi
set -- "${args[@]}"
if [ "${1:-}" = --version ]; then
  exec env PATH="$ORIG_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$ORIG_PATH" "$HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH"
export HERDR_SESSION=$LAB

WTS=""
cleanup() {
  local wt
  for wt in $WTS; do treehouse return --force "$wt" >/dev/null 2>&1 || true; done
  PATH="$ORIG_PATH" "$HELPER" teardown "$LAB" && echo "lab $LAB torn down"
  rm -rf "$W"
}
trap cleanup EXIT

say "environment"
echo "herdr: $(env PATH="$ORIG_PATH" herdr --version)"
env PATH="$ORIG_PATH" herdr plugin list
echo "lab session: $LAB"
PATH="$ORIG_PATH" "$HELPER" provision "$LAB" || { echo "provision failed"; exit 1; }

FMH=$W/home
PROJ=$W/project
mkdir -p "$FMH/state" "$FMH/config" "$FMH/data"
touch "$FMH/state/.last-watcher-beat"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
echo '# plugin dock fixture' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

brief() {
  mkdir -p "$FMH/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nPlugin dock fixture %s.\n\n## Firstmate spec\nVerify.\n' "$1" > "$FMH/data/$1/brief.md"
}
spawn() {
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$FMH" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$1" "$PROJ" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr
}
teardown() {
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$FMH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$FMH/state" \
    FM_DATA_OVERRIDE="$FMH/data" FM_CONFIG_OVERRIDE="$FMH/config" "$ROOT/bin/fm-teardown.sh" "$1" --force
}
metav() { grep "^$2=" "$FMH/state/$1.meta" | cut -d= -f2-; }
remember() { local wt; wt=$(metav "$1" worktree 2>/dev/null || true); [ -z "$wt" ] || WTS="$WTS $wt"; }
tabpanes() { lab pane list --workspace "$1" | jq -c --arg t "$2" '[.result.panes[] | select(.tab_id == $t) | {pane_id, label: (.label // null), tokens: (.tokens // null)}]'; }
wspanes() { lab pane list --workspace "$1" | jq -c '[.result.panes[] | {pane_id, tab_id, label: (.label // null), tokens: (.tokens // null)}]'; }

say "S0 control: a raw --no-focus tab create in this lab gets an Explorer plugin pane docked by herdr-sidebar"
CTRL=$(lab workspace create --cwd "$PROJ" --label ctrl --no-focus)
CTRL_WS=$(printf '%s' "$CTRL" | jq -r .result.workspace.workspace_id)
sleep 2
CT=$(lab tab create --workspace "$CTRL_WS" --cwd "$PROJ" --label ctrl-tab --no-focus)
CT_TAB=$(printf '%s' "$CT" | jq -r .result.tab.tab_id)
sleep 2
echo "control tab panes: $(tabpanes "$CTRL_WS" "$CT_TAB")"
if tabpanes "$CTRL_WS" "$CT_TAB" | jq -e 'length == 2 and any(.[]; .label == "Explorer")' >/dev/null; then
  ok "herdr-sidebar docks an Explorer pane into a fresh tab (the reported trigger is live here)"
else
  bad "control did not reproduce the plugin dock; later scenarios would not exercise the fix"
fi
lab workspace close "$CTRL_WS" >/dev/null

say "S1 flat create (config off): task tab holds exactly the task pane despite the plugin"
printf 'off\n' > "$FMH/config/herdr-presentation-spaces"
brief flat1
if spawn flat1 > "$W/flat1.out" 2> "$W/flat1.err"; then
  remember flat1
  FWS=$(metav flat1 herdr_workspace_id); FTAB=$(metav flat1 herdr_tab_id); FPANE=$(metav flat1 herdr_pane_id)
  sleep 2
  P=$(tabpanes "$FWS" "$FTAB"); echo "meta pane=$FPANE tab=$FTAB; tab panes after 2s: $P"
  if printf '%s' "$P" | jq -e --arg p "$FPANE" '. == [{pane_id:$p,label:.[0].label,tokens:.[0].tokens}] and all(.[]; .label != "Explorer")' >/dev/null; then
    ok "flat task tab = exactly the recorded task pane, no Explorer"
  else
    bad "flat task tab shape: $P"
  fi
  say "S2 recovery discovery: fm_backend_herdr_list_live names the flat task pane"
  LIVE=$(FM_HOME="$FMH" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_list_live "$1"' "$ROOT" "$LAB")
  echo "list_live: $LIVE"
  printf '%s\n' "$LIVE" | grep -F "$LAB:$FPANE" >/dev/null && ok "list_live resolves flat1 to its task pane" || bad "list_live did not resolve flat1"
else
  bad "flat spawn failed: $(cat "$W/flat1.err")"
fi

say "S3 projected create with UNCONFIGURED herdr-presentation-spaces (the reported failure)"
rm -f "$FMH/config/herdr-presentation-spaces"
brief tangent-geom-s1
if spawn tangent-geom-s1 > "$W/proj.out" 2> "$W/proj.err"; then
  remember tangent-geom-s1
  echo "spawn stderr:"; sed 's/^/  /' "$W/proj.err"
  PWS=$(metav tangent-geom-s1 herdr_workspace_id); PTAB=$(metav tangent-geom-s1 herdr_tab_id); PPANE=$(metav tangent-geom-s1 herdr_pane_id)
  J=$FMH/state/tangent-geom-s1.herdr-presentation
  echo "journal:"; sed 's/^/  /' "$J"
  echo "workspace label: $(lab workspace get "$PWS" | jq -r .result.workspace.label)"
  echo "tabs: $(lab tab list --workspace "$PWS" | jq -c '[.result.tabs[] | {tab_id,label}]')"
  sleep 2
  WP=$(wspanes "$PWS"); echo "workspace panes after 2s: $WP"
  if printf '%s' "$WP" | jq -e --arg p "$PPANE" --arg t "$PTAB" 'length == 1 and .[0].pane_id == $p and .[0].tab_id == $t and .[0].label != "Explorer"' >/dev/null \
     && grep -q '^version=2' "$J" && [ "$PWS" != "$FWS" ]; then
    ok "projected workspace converged to exactly the task pane; journal advanced to version 2"
  else
    bad "projected shape/journal unexpected"
  fi
  grep -q 'did not converge' "$W/proj.err" && bad "spawn printed the convergence error"
  echo "task pane content (first lines):"; lab pane read "$PPANE" --lines 5 2>&1 | head -c 600; echo
else
  bad "projected spawn failed: $(cat "$W/proj.err")"
  ls "$FMH/state"
fi

say "S4 projected kill with Explorer re-docked: focusing the task tab makes herdr-sidebar re-dock; teardown leaves no Explorer-only workspace"
if [ -n "${PWS:-}" ]; then
  BEFORE=$(lab workspace list | jq -c '[.result.workspaces[] | select(.focused) | {workspace_id, active_tab_id}]')
  lab tab focus "$PTAB" >/dev/null; sleep 2
  echo "after focusing task tab: $(wspanes "$PWS")"
  teardown tangent-geom-s1 > "$W/pt.out" 2> "$W/pt.err" || echo "teardown rc!=0: $(tail -3 "$W/pt.err")"
  sleep 1
  if lab workspace get "$PWS" >/dev/null 2>&1; then
    bad "projected workspace survived teardown: $(wspanes "$PWS")"
  else
    ok "projected workspace removed by teardown (no Explorer-only workspace left)"
  fi
  echo "workspaces now: $(lab workspace list | jq -c '[.result.workspaces[] | {workspace_id,label}]')"
fi

say "S5 adversarial: an unregistered captain split beside the flat task pane is never closed by the plugin prune"
if [ -n "${FPANE:-}" ]; then
  SPLIT=$(lab pane split "$FPANE" --direction right --no-focus 2>&1)
  SPANE=$(printf '%s' "$SPLIT" | jq -r '.result.pane.pane_id // .result.pane_id // empty' 2>/dev/null)
  echo "captain split pane: ${SPANE:-<none>} ($SPLIT)" | cut -c1-300
  sleep 1
  echo "flat tab before teardown: $(tabpanes "$FWS" "$FTAB")"
  teardown flat1 > "$W/ft.out" 2> "$W/ft.err" || echo "teardown rc!=0: $(tail -3 "$W/ft.err")"
  sleep 1
  echo "flat tab after teardown: $(tabpanes "$FWS" "$FTAB")"
  if [ -n "$SPANE" ] && lab pane get "$SPANE" >/dev/null 2>&1; then
    ok "captain split pane $SPANE survived the task teardown"
  else
    bad "captain split pane was closed or never created"
  fi
  lab pane get "$FPANE" >/dev/null 2>&1 && bad "flat task pane still alive after teardown" || ok "flat task pane closed by teardown"
  echo "direct probe: plugin pane close on the captain split pane:"
  lab plugin pane close "$SPANE" 2>&1 | sed 's/^/  /'
  lab pane get "$SPANE" >/dev/null 2>&1 && ok "Herdr refused plugin pane close on an unregistered pane" || bad "split pane gone after probe"
fi

say "summary"
echo "failures: $FAILS"
exit "$FAILS"
