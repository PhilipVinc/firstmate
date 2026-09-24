#!/usr/bin/env bash
# Live driver v2: real fm-spawn.sh / fm-teardown.sh / adapter functions against a
# guarded fm-lab-* Herdr 0.9.1 session in an ISOLATED throwaway Herdr home
# (HOME/XDG_CONFIG_HOME under /tmp) whose only plugin is a copy of
# herdr-sidebar 0.13.0, enabled. The operator's real Herdr home, its default
# session, and its plugin state are never addressed.
# Usage: plugin-dock-live-v2.sh <code-root> <helper-root> <isolated-home> <tag>
set -u
ROOT=$1; HROOT=$2; H=$3; TAG=$4
export HOME=$H XDG_CONFIG_HOME=$H/.config
unset HERDR_BIN_PATH HERDR_STARTUP_CWD HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION FM_TASK_ID
export FM_GATE_REFUSE_BYPASS=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
ORIG_PATH=$PATH
REAL_HERDR=$(command -v herdr)
HELPER=$HROOT/bin/fm-herdr-lab.sh
W=$(mktemp -d /tmp/fmtest-pd2.XXXX)
FAKEBIN=$W/bin; mkdir -p "$FAKEBIN"
LAB=$("$HELPER" name "pd$TAG")
export ORIG_PATH REAL_HERDR HELPER HERDR_LAB_SESSION=$LAB
FAILS=0
say() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS + 1)); }
lab() { PATH="$ORIG_PATH" "$HELPER" run "$LAB" "$@"; }
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@"); n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n - 2))]}" = --session ] && [ "${args[$((n - 1))]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$((n - 1))]" "args[$((n - 2))]"
fi
set -- "${args[@]}"
if [ "${1:-}" = --version ]; then exec env PATH="$ORIG_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"; fi
# read-only session enumeration (resolve_bare_selector) stays in the isolated home
if [ "${1:-}" = session ] && [ "${2:-}" = list ]; then exec env PATH="$ORIG_PATH" "$REAL_HERDR" "$@"; fi
exec env PATH="$ORIG_PATH" "$HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH" HERDR_SESSION=$LAB
WTS=""
cleanup() {
  local wt
  for wt in $WTS; do treehouse return --force "$wt" >/dev/null 2>&1 || true; done
  PATH="$ORIG_PATH" "$HELPER" teardown "$LAB" && echo "lab $LAB torn down"
  rm -rf "$W"
}
trap cleanup EXIT
say "environment ($TAG: code=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || cat "$ROOT/.rev"))"
echo "herdr: $(env PATH="$ORIG_PATH" herdr --version)"; env PATH="$ORIG_PATH" herdr plugin list; echo "lab session: $LAB"
PATH="$ORIG_PATH" "$HELPER" provision "$LAB" || { echo "provision failed"; exit 1; }
FMH=$W/home; PROJ=$W/project
mkdir -p "$FMH/state" "$FMH/config" "$FMH/data" "$PROJ"; touch "$FMH/state/.last-watcher-beat"
git -C "$PROJ" init -q; echo '# fixture' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
brief() { mkdir -p "$FMH/data/$1"; printf '# Task\n## Captain'"'"'s intent\nFixture %s.\n\n## Firstmate spec\nVerify.\n' "$1" > "$FMH/data/$1/brief.md"; }
spawn() { FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$FMH" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "$1" "$PROJ" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr; }
teardown() { FM_GATE_REFUSE_BYPASS=1 FM_HOME="$FMH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$FMH/state" \
  FM_DATA_OVERRIDE="$FMH/data" FM_CONFIG_OVERRIDE="$FMH/config" "$ROOT/bin/fm-teardown.sh" "$1" --force; }
adapter() { FM_HOME="$FMH" bash -c '. "$0/bin/backends/herdr.sh"; "$@"' "$ROOT" "$@"; }
metav() { grep "^$2=" "$FMH/state/$1.meta" | cut -d= -f2-; }
remember() { local wt; wt=$(metav "$1" worktree 2>/dev/null || true); [ -z "$wt" ] || WTS="$WTS $wt"; }
tabpanes() { lab pane list --workspace "$1" | jq -c --arg t "$2" '[.result.panes[] | select(.tab_id == $t) | {pane_id: .pane_id, label: (.label // null), plugin_tokens: ((.tokens // {}) | keys)}]'; }
wspanes() { lab pane list --workspace "$1" | jq -c '[.result.panes[] | {pane_id: .pane_id, tab_id: .tab_id, label: (.label // null), plugin_tokens: ((.tokens // {}) | keys)}]'; }

say "S0 control: a raw --no-focus tab create in this lab gets a herdr-sidebar pane docked"
CTRL_WS=$(lab workspace create --cwd "$PROJ" --label ctrl --no-focus | jq -r .result.workspace.workspace_id); sleep 2
CT_TAB=$(lab tab create --workspace "$CTRL_WS" --cwd "$PROJ" --label ctrl-tab --no-focus | jq -r .result.tab.tab_id); sleep 2
P=$(tabpanes "$CTRL_WS" "$CT_TAB"); echo "control tab panes: $P"
printf '%s' "$P" | jq -e 'length == 2 and any(.[]; .plugin_tokens | index("herdr-sidebar-explorer"))' >/dev/null \
  && ok "herdr-sidebar docks its explorer pane into a fresh tab (the reported trigger is live here)" || bad "control did not reproduce the plugin dock"
lab workspace close "$CTRL_WS" >/dev/null

say "S2 flat spawn (config off): task tab holds exactly the task pane; list_live and resolve_bare_selector find it"
printf 'off\n' > "$FMH/config/herdr-presentation-spaces"
brief flat1
if spawn flat1 > "$W/flat1.out" 2> "$W/flat1.err"; then
  remember flat1
  FWS=$(metav flat1 herdr_workspace_id); FTAB=$(metav flat1 herdr_tab_id); FPANE=$(metav flat1 herdr_pane_id)
  sleep 2; P=$(tabpanes "$FWS" "$FTAB"); echo "meta pane=$FPANE tab=$FTAB; tab panes after 2s: $P"
  printf '%s' "$P" | jq -e --arg p "$FPANE" 'length == 1 and .[0].pane_id == $p' >/dev/null && ok "flat task tab = exactly the task pane" || bad "flat task tab shape: $P"
  LIVE=$(adapter fm_backend_herdr_list_live "$LAB"); echo "list_live: $LIVE"
  printf '%s\n' "$LIVE" | grep -qF "$LAB:$FPANE" && ok "list_live -> $FPANE" || bad "list_live missed flat1"
  R=$(adapter fm_backend_herdr_resolve_bare_selector fm-flat1 2>&1); echo "resolve_bare_selector fm-flat1: $R"
  [ "$R" = "$LAB:$FPANE" ] && ok "resolve_bare_selector -> $FPANE" || bad "resolve_bare_selector: $R"
else bad "flat spawn failed: $(cat "$W/flat1.err")"; fi

rm -f "$FMH/config/herdr-presentation-spaces"
say "S1 projected spawn with UNCONFIGURED herdr-presentation-spaces (the reported failure)"
brief tangent-geom-s1
if spawn tangent-geom-s1 > "$W/proj.out" 2> "$W/proj.err"; then
  remember tangent-geom-s1
  PWS=$(metav tangent-geom-s1 herdr_workspace_id); PTAB=$(metav tangent-geom-s1 herdr_tab_id); PPANE=$(metav tangent-geom-s1 herdr_pane_id)
  J=$FMH/state/tangent-geom-s1.herdr-presentation
  echo "spawn rc=0; journal:"; sed 's/^/  /' "$J"
  echo "workspace label: $(lab workspace get "$PWS" | jq -r .result.workspace.label)"
  sleep 2; WP=$(wspanes "$PWS"); echo "projected workspace panes after 2s: $WP"
  if printf '%s' "$WP" | jq -e --arg p "$PPANE" --arg t "$PTAB" 'length == 1 and .[0].pane_id == $p and .[0].tab_id == $t and (.[0].plugin_tokens | length) == 0' >/dev/null && grep -q '^version=2' "$J"; then
    ok "projected spawn succeeded; workspace holds exactly the task pane; journal version 2"
  else bad "projected shape/journal unexpected"; fi
else
  bad "projected spawn failed rc!=0"; echo "stderr:"; sed 's/^/  /' "$W/proj.err"
  echo "state:"; ls "$FMH/state"; [ -f "$FMH/state/tangent-geom-s1.herdr-presentation" ] && sed 's/^/  journal: /' "$FMH/state/tangent-geom-s1.herdr-presentation"
  echo "workspaces: $(lab workspace list | jq -c '[.result.workspaces[] | {id: .workspace_id, label: .label}]')"
  for ws in $(lab workspace list | jq -r '.result.workspaces[] | select(.label | test("tangent")) | .workspace_id'); do echo "leftover $ws panes: $(wspanes "$ws")"; done
fi


say "R1 re-dock after activation: toggle focus between the projected and flat task tabs until herdr-sidebar re-docks into the flat tab"
RED=0
for i in 1 2 3 4 5 6; do
  lab tab focus "$PTAB" >/dev/null; sleep 2; lab tab focus "$FTAB" >/dev/null; sleep 3
  P=$(tabpanes "$FWS" "$FTAB"); echo "round $i flat tab panes (raw pane list, no adapter): $P"
  printf '%s' "$P" | jq -e 'length > 1 and any(.[]; .plugin_tokens | index("herdr-sidebar-explorer"))' >/dev/null && { RED=1; break; }
done
if [ $RED = 1 ]; then
  ok "plugin re-docked into the flat task tab after activation (reported trigger reproduced)"
  LIVE=$(adapter fm_backend_herdr_list_live "$LAB"); echo "list_live: ${LIVE:-<empty>}"
  printf '%s\n' "$LIVE" | grep -qF "$LAB:$FPANE" && ok "list_live resolves flat1 -> $FPANE after re-dock" || bad "list_live skips flat1 after re-dock"
  echo "flat tab after list_live: $(tabpanes "$FWS" "$FTAB")"
  # force another re-dock before resolve, if the plugin cooperates
  lab tab focus "$PTAB" >/dev/null; sleep 2; lab tab focus "$FTAB" >/dev/null; sleep 3; echo "flat tab before resolve: $(tabpanes "$FWS" "$FTAB")"
  R=$(adapter fm_backend_herdr_resolve_bare_selector fm-flat1 2>&1); echo "resolve_bare_selector fm-flat1: $R"
  [ "$R" = "$LAB:$FPANE" ] && ok "resolve_bare_selector after re-dock" || bad "resolve_bare_selector after re-dock: $R"
  lab tab focus "$PTAB" >/dev/null; sleep 2; lab tab focus "$FTAB" >/dev/null; sleep 3; echo "flat tab before respawn: $(tabpanes "$FWS" "$FTAB")"
  echo "husk classification of $FPANE: $(adapter fm_backend_herdr_pane_agent_state "$LAB" "$FPANE")"
  OUT=$(adapter fm_backend_herdr_create_task "$LAB:$FWS" fm-flat1 "$PROJ" "" 2>&1); rc=$?
  echo "respawn over re-docked husk: rc=$rc out=$OUT"
  if [ $rc = 0 ]; then
    NTAB=${OUT%% *}; NPANE=${OUT##* }; sleep 2
    P=$(tabpanes "$FWS" "$NTAB"); echo "replacement tab panes: $P; old pane alive? $(lab pane get "$FPANE" >/dev/null 2>&1 && echo yes || echo no)"
    printf '%s' "$P" | jq -e --arg p "$NPANE" 'length == 1 and .[0].pane_id == $p' >/dev/null && ! lab pane get "$FPANE" >/dev/null 2>&1 \
      && ok "respawn over re-docked husk replaced it with a one-pane tab" || bad "respawn shape after re-dock"
    FTAB=$NTAB; FPANE=$NPANE
  else bad "respawn over re-docked husk refused"; fi
else echo "NOTE: plugin did not re-dock in 6 focus rounds; re-dock path not exercised"; FAILS=$((FAILS + 100)); fi

say "R2 teardown"
teardown tangent-geom-s1 >/dev/null 2>&1; teardown flat1 >/dev/null 2>&1; adapter fm_backend_herdr_kill "$LAB:$FPANE"; sleep 1
lab pane get "$FPANE" >/dev/null 2>&1 && bad "flat pane alive" || ok "flat task pane closed"
echo "workspaces now: $(lab workspace list | jq -c '[.result.workspaces[] | {id: .workspace_id, label: .label, panes: (.pane_count // null)}]')"
for ws in $(lab workspace list | jq -r '.result.workspaces[].workspace_id'); do echo "$ws panes: $(wspanes "$ws")"; done
say "summary"; echo "failures: $FAILS"; exit "$FAILS"
