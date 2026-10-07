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
