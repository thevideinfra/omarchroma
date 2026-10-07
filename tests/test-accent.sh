#!/usr/bin/env bash
# The accent the synchronized apps use is the theme's own, unless the user
# picked another color from the theme's palette. It is applied where every
# generator reads the palette from, so these pin the resolver, the command that
# records the choice, and the panel's picker.
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd -- "$REPO" || exit 1
chk(){ [[ $2 == "$3" ]] && echo "  PASS $1" || echo "  FAIL $1: got [$2] want [$3]"; }
P=lib/hyprchroma-palette

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export HOME=$ROOT
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
T=$ROOT/cfg; S=$ROOT/state
mkdir -p "$T/hyprchroma" "$S/hyprchroma"

write_palette() {
  ./$P --template \
    | sed -e 's/^accent = .*/accent = "#111111"/' \
          -e 's/^blue = .*/blue = "#0000ff"/' \
          -e 's/^red = .*/red = "#ff0000"/' > "$T/hyprchroma/palette.toml"
  if [[ ${1:-} == optional ]]; then
    printf 'cyan = "#00ffff"\norange = "#ff8800"\n' >> "$T/hyprchroma/palette.toml"
  fi
}
accent() { XDG_CONFIG_HOME=$T XDG_STATE_HOME=$S timeout 5 ./$P accent; }
set_accent() { printf '%s' "$1" > "$S/hyprchroma/settings.json"; }

echo "--- resolver ---"
write_palette optional
rm -f "$S/hyprchroma/settings.json"
chk "no settings file: the theme's accent" "$(accent)" "#111111"
set_accent '{"accent":"theme"}'
chk "theme: the theme's accent" "$(accent)" "#111111"
set_accent '{"accent":"blue"}'
chk "blue: the palette's blue" "$(accent)" "#0000ff"
set_accent '{"accent":"red"}'
chk "red: the palette's red" "$(accent)" "#ff0000"
set_accent '{"accent":"cyan"}'
chk "cyan, an optional key, when the palette has it" "$(accent)" "#00ffff"
set_accent '{"accent":"orange"}'
chk "orange, an optional key, when the palette has it" "$(accent)" "#ff8800"

write_palette
set_accent '{"accent":"cyan"}'
chk "a color the palette lacks falls back to the theme's accent" "$(accent)" "#111111"

write_palette optional
for bad in '{"accent":"bogus"}' '{"accent":["blue"]}' '{"accent":7}' 'not json' '[]' '{"accent":"#0000ff"}'; do
  set_accent "$bad"
  chk "an unusable setting is ignored: $bad" "$(accent)" "#111111"
done
rm -f "$S/hyprchroma/settings.json"; mkfifo "$S/hyprchroma/settings.json"
chk "a fifo planted as the settings file does not hang the resolver" "$(accent)" "#111111"
rm -f "$S/hyprchroma/settings.json"

echo "--- every way of asking sees it ---"
set_accent '{"accent":"blue"}'
chk "--all" "$(XDG_CONFIG_HOME=$T XDG_STATE_HOME=$S ./$P --all | grep -c "^accent	#0000ff$")" "1"
chk "--for-sync" "$(XDG_CONFIG_HOME=$T XDG_STATE_HOME=$S ./$P --for-sync | grep -c "^accent	#0000ff$")" "1"

echo "--- template and capture ---"
chk "the template names the optional colors, commented out" \
  "$(./$P --template | grep -c '^# \(cyan\|orange\) = ')" "2"
chk "REQUIRED is unchanged: the template still carries 20 live keys" \
  "$(./$P --template | grep -c '^[a-z_]* = "#')" "20"
if command -v omarchy >/dev/null; then
  source "$REPO/tests/lib-omarchy.sh"
  seed_omarchy_theme
  set_accent '{"accent":"blue"}'
  with=$(XDG_STATE_HOME=$S ./$P --capture)
  rm -f "$S/hyprchroma/settings.json"
  without=$(XDG_STATE_HOME=$S ./$P --capture)
  chk "palette --capture ignores the chosen accent" \
    "$([[ $with == "$without" ]] && echo same || echo differs)" "same"
fi

echo "--- the command ---"
# The sync script's layout is derived from the binary's own location, so the
# fake tree is a real one with a stub state helper that logs and writes.
CLI=$(mktemp -d)
trap 'rm -rf "$ROOT" "$CLI"' EXIT
(
  export HOME=$CLI XDG_STATE_HOME=$CLI/state XDG_DATA_HOME=$CLI/data XDG_RUNTIME_DIR=$CLI/run
  unset XDG_CONFIG_HOME
  source "$REPO/tests/lib-omarchy.sh"
  seed_omarchy_theme
  mkdir -p "$XDG_RUNTIME_DIR" "$CLI/lib" "$CLI/bin" "$XDG_STATE_HOME/hyprchroma"
  cp "$REPO"/lib/hyprchroma-* "$REPO"/lib/sync-* "$CLI/lib/"
  cp "$REPO/bin/hyprchroma" "$CLI/bin/hyprchroma"
  cp -r "$REPO/share" "$CLI/share"
  cat > "$CLI/lib/hyprchroma-state" <<'E'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  case $a in prepare-lock) lock=1 ;; write-file) writing=1 ;; esac
  case $prev in
    --path) [[ ${lock:-0} == 1 ]] && : > "$a"
            [[ ${writing:-0} == 1 ]] && cat > "$a" ;;
  esac
  prev=$a
done
exit 0
E
  chmod +x "$CLI/lib/hyprchroma-state"
  printf '#!/usr/bin/env bash\n[[ $1 == --info ]] && echo "{}"\nexit 0\n' > "$CLI/lib/hyprchroma-dark-reader"
  chmod +x "$CLI/lib/hyprchroma-dark-reader"
  settings=$XDG_STATE_HOME/hyprchroma/settings.json
  run() { bash "$CLI/bin/hyprchroma" "$@" >/dev/null 2>&1; }

  run --set-accent=blue --quiet
  chk "--set-accent records the choice" "$(jq -r '.accent' "$settings")" "blue"
  chk "...beside the framework settings, not instead of them" \
    "$(jq -r '.accent + "," + (.frameworks | has("gtk") | tostring)' "$settings" 2>/dev/null || echo none)" "blue,true"
  blue=$("$CLI/lib/hyprchroma-palette" blue)
  chk "...and the synchronized GTK stylesheet uses that color as its accent" \
    "$(grep -c "@define-color accent_bg_color $blue;" "$HOME/.config/gtk-4.0/hyprchroma.css")" "1"
  run --set-accent=theme --quiet
  chk "--set-accent=theme records the theme" "$(jq -r '.accent' "$settings")" "theme"
  chk "...and the stylesheet follows the theme's own accent again" \
    "$(grep -c "@define-color accent_bg_color $("$CLI/lib/hyprchroma-palette" accent);" "$HOME/.config/gtk-4.0/hyprchroma.css")" "1"
  run --set-accent=cyan --quiet
  before=$(cat "$settings")
  bash "$CLI/bin/hyprchroma" --set-accent=bogus --quiet >/dev/null 2>&1
  chk "an unknown accent is refused with a non-zero exit" "$?" "1"
  chk "...and the setting is left as it was" "$([[ $(cat "$settings") == "$before" ]] && echo same || echo changed)" "same"
)

echo "--- wiring ---"
chk "the sync fingerprint includes the resolved accent, so a change always rewrites files" \
  "$(grep -c '"\$bright_foreground" "\$accent"' bin/hyprchroma)" "1"
chk "the daemon already watches settings.json for changes" \
  "$(grep -c 'theme.name", state_dir / "settings.json")' lib/hyprchroma-state)" "1"
chk "a held lock is waited for, not skipped, for an accent change" \
  "$(grep -c 'force == 0 && -z \$set_enabled && -z \$set_accent' bin/hyprchroma)" "1"

echo "--- the panel ---"
names_py=$(grep -o '^ACCENT_CHOICES = (.*)' lib/hyprchroma-palette | grep -o '"[a-z]*"' | tr -d '"' | paste -sd, -)
names_qml=$(grep -o 'readonly property var names: \[.*\]' ThemePalette.qml | grep -o '"[a-z]*"' | tr -d '"' | paste -sd, -)
chk "the picker offers exactly the colors the service accepts" "$names_qml" "$names_py"
chk "the picker lists the theme first, then what the theme defines" \
  "$(grep -c 'var list = \["theme"\]' ThemePalette.qml)" "1"
chk "the theme's colors are read from its colors.toml and re-read when it changes" \
  "$(grep -cE '/colors.toml"|watchChanges: true' ThemePalette.qml)" "2"
chk "the panel reads the saved choice from settings.json" \
  "$(grep -c 'parsed.accent' Panel.qml)" "1"
chk "...and accepts only a name the picker knows" \
  "$(grep -c 'themePalette.names.indexOf(picked)' Panel.qml)" "1"
chk "picking runs the service's flag" \
  "$(grep -c '"--set-accent=" + name' Panel.qml)" "1"
chk "the swatches come from the theme's palette" \
  "$(grep -c 'model: themePalette.available' Panel.qml)" "1"
chk "the panel's own accent is untouched by the choice" \
  "$(grep -c 'readonly property color accent: Color.accent' Panel.qml)" "1"
chk "the picker says what it applies to" \
  "$(grep -c 'Applies to synchronized apps, not this panel' Panel.qml)" "1"
