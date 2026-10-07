#!/usr/bin/env bash
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SETTINGS_FILE=$(mktemp)
target_key() { case "$1" in gtk) printf gtk;; qt-kde) printf qtKde;; dark-reader) printf darkReader;; *) return 1;; esac; }
eval "$(sed -n '/^target_enabled()/,/^}$/p' $REPO/bin/hyprchroma)"
msg() {
  printf '%s' "$1" > "$SETTINGS_FILE"; qt_kde_deferred=$2
  local synced=() message
  target_enabled gtk && synced+=("GTK")
  if target_enabled qt-kde; then (( qt_kde_deferred )) || synced+=("Qt/KDE"); fi
  target_enabled dark-reader && synced+=("Dark Reader")
  if (( ${#synced[@]} == 0 )); then message="nothing to synchronize; every framework is switched off"
  else message=$(printf '%s, ' "${synced[@]}"); message="${message%, } synchronized"; fi
  if target_enabled qt-kde && (( qt_kde_deferred )); then message+="; Qt/KDE deferred while KDE apps are open"; fi
  printf '%s' "$message"
}
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
# The closing line of a sync names what was actually written, so it has to
# track the toggles and the Qt/KDE deferral --
# claiming a framework was synchronized when it was skipped is worse than
# saying nothing.
chk "everything on" \
  "$(msg '{"frameworks":{}}' 0)" \
  "GTK, Qt/KDE, Dark Reader synchronized"
chk "two switched off are not claimed" \
  "$(msg '{"frameworks":{"gtk":false,"qtKde":false}}' 0)" \
  "Dark Reader synchronized"
chk "everything off says so plainly" \
  "$(msg '{"frameworks":{"gtk":false,"qtKde":false,"darkReader":false}}' 0)" \
  "nothing to synchronize; every framework is switched off"
chk "a deferred Qt/KDE is reported as deferred, not synchronized" \
  "$(msg '{"frameworks":{}}' 1)" \
  "GTK, Dark Reader synchronized; Qt/KDE deferred while KDE apps are open"
chk "switched off beats deferred: it is not mentioned at all" \
  "$(msg '{"frameworks":{"qtKde":false}}' 1)" \
  "GTK, Dark Reader synchronized"
rm -f "$SETTINGS_FILE"
