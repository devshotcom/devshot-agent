#!/bin/sh
# Spec 459 — exercise `wp devshot elementor` against a real WordPress with
# Elementor. Run it in the WordPress root (a LAMP VM: /var/www/wordpress).
# It works on a test page it creates and deletes; live pages are only read
# (dump of the first Elementor page, when there is one). The kit is set and
# restored. Exits non-zero on the first failed expectation.
set -u

WP="wp --allow-root"
fails=0
page=""

json() { # json <php expression on $d> — reads JSON from stdin
  php -r '$d = json_decode(stream_get_contents(STDIN), true); $v = '"$1"'; echo is_scalar($v) ? $v : json_encode($v);'
}
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1" >&2; fails=$((fails + 1)); }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$3], got [$2]"; fi; }
expect_exit() { # expect_exit <name> <code> <command...>
  name="$1"; want="$2"; shift 2
  out="$("$@" 2>&1)"; got=$?
  if [ "$got" = "$want" ]; then ok "$name (exit $got)"; else bad "$name: exit $got, wanted $want: $out"; fi
}
cleanup() { [ -n "$page" ] && $WP post delete "$page" --force >/dev/null 2>&1; }
trap cleanup EXIT

$WP devshot elementor widgets >/dev/null || { echo "FAIL wp devshot elementor is not registered" >&2; exit 1; }

page="$($WP post create --post_type=page --post_status=draft --post_title='DevShot Elementor check' --porcelain)"
tmp="$(mktemp -d)"

cat > "$tmp/tree.json" <<'JSON'
[{"elType":"container","settings":{"_css_classes":"check-hero"},"elements":[
  {"elType":"widget","widgetType":"heading","settings":{"title":"Erste Überschrift","header_size":"h1"}},
  {"elType":"widget","widgetType":"text-editor","settings":{"editor":"<p>Absatz</p>"}}
]}]
JSON
out="$($WP devshot elementor apply "$page" --file="$tmp/tree.json")" || bad "apply"
expect_eq "apply saves two-level tree" "$(echo "$out" | json '$d["elements"]')" "1"

dump="$($WP devshot elementor dump "$page")" || bad "dump"
container="$(echo "$dump" | json '$d["elements"][0]["id"]')"
heading="$(echo "$dump" | json '$d["elements"][0]["elements"][0]["id"]')"
expect_eq "new ids are 7 hex" "$(echo "$container$heading" | grep -Ec '^[0-9a-f]{14}$')" "1"
expect_eq "dump shows css_classes" "$(echo "$dump" | json '$d["elements"][0]["css_classes"]')" "check-hero"
expect_eq "dump shows the widget type" "$(echo "$dump" | json '$d["elements"][0]["elements"][0]["widgetType"]')" "heading"
expect_eq "dump keeps non-default settings" "$(echo "$dump" | json '$d["elements"][0]["elements"][0]["settings"]["header_size"]')" "h1"
expect_eq "dump --id narrows to one element" "$($WP devshot elementor dump "$page" --id="$heading" | json '$d["id"]')" "$heading"

widget="$($WP devshot elementor widget heading)" || bad "widget heading"
expect_eq "widget lists header_size options" "$(echo "$widget" | json 'in_array("h1", array_column($d["controls"], null, "name")["header_size"]["options"]) ? "yes" : "no"')" "yes"
expect_eq "widget lists style controls with responsive variants" "$(echo "$widget" | json '(function ($r) { sort($r); return implode(",", $r); })(array_column($d["controls"], null, "name")["align"]["responsive"] ?? [])')" "align_mobile,align_tablet"
expect_eq "widget container works for element types" "$($WP devshot elementor widget container | json '$d["name"]')" "container"

out="$($WP devshot elementor patch "$page" --id="$heading" --set='{"title":"Geänderte Überschrift","align":"center","align_mobile":"start"}')" || bad "patch"
expect_eq "patch reports the old value" "$(echo "$out" | json '$d["before"]["title"]')" "Erste Überschrift"
expect_eq "patch is saved" "$($WP devshot elementor dump "$page" --id="$heading" | json '$d["settings"]["title"]')" "Geänderte Überschrift"
expect_eq "patch flushes CSS" "$(echo "$out" | json '$d["css_flushed"] ? "yes" : "no"')" "yes"
expect_eq "rendered page carries the new heading" "$($WP eval "echo \Elementor\Plugin::\$instance->frontend->get_builder_content($page);" | grep -c 'Geänderte Überschrift')" "1"
expect_eq "document save left a revision" "$([ "$($WP post list --post_type=revision --post_parent="$page" --format=count)" -ge 1 ] && echo yes)" "yes"

printf '%s' '{"elType":"widget","widgetType":"button","settings":{"text":"Mehr"}}' > "$tmp/button.json"
out="$($WP devshot elementor insert "$page" --parent="$container" --after="$heading" --file="$tmp/button.json")" || bad "insert"
button="$(echo "$out" | json '$d["inserted"][0]')"
expect_eq "insert lands after the heading" "$($WP devshot elementor dump "$page" | json '$d["elements"][0]["elements"][1]["id"]')" "$button"

out="$($WP devshot elementor remove "$page" --id="$button")" || bad "remove"
expect_eq "remove drops the element" "$($WP devshot elementor dump "$page" | json 'count($d["elements"][0]["elements"])')" "2"

expect_exit "unknown setting is refused" 4 $WP devshot elementor patch "$page" --id="$heading" --set='{"no_such_setting":1}'
expect_exit "select value outside options is refused" 4 $WP devshot elementor patch "$page" --id="$heading" --set='{"header_size":"h9"}'
expect_exit "unknown element id" 3 $WP devshot elementor patch "$page" --id=zzzzzzz --set='{"title":"x"}'
expect_exit "unknown widget" 3 $WP devshot elementor widget no-such-widget
expect_exit "unregistered widget is not inserted" 4 sh -c "printf '%s' '{\"elType\":\"widget\",\"widgetType\":\"no-such\"}' > $tmp/x.json && $WP devshot elementor insert $page --parent=root --file=$tmp/x.json"
expect_exit "malformed --set" 2 $WP devshot elementor patch "$page" --id="$heading" --set='{oops'
expect_exit "missing post" 3 $WP devshot elementor dump 99999999
expect_eq "refused writes changed nothing" "$($WP devshot elementor dump "$page" --id="$heading" | json '$d["settings"]["header_size"]')" "h1"

kit_before="$($WP devshot elementor kit get)" || bad "kit get"
colors="$(echo "$kit_before" | json 'json_encode($d["settings"]["custom_colors"] ?? [])')"
$WP devshot elementor kit set --set='{"custom_colors":[{"_id":"c459abc","title":"Check","color":"#123456"}]}' >/dev/null || bad "kit set"
expect_eq "kit set is saved" "$($WP devshot elementor kit get | json '$d["settings"]["custom_colors"][0]["color"]')" "#123456"
expect_exit "unknown kit setting is refused" 4 $WP devshot elementor kit set --set='{"no_such_kit_key":1}'
$WP devshot elementor kit set --set="{\"custom_colors\":$colors}" >/dev/null || bad "kit restore"
expect_eq "kit restored" "$($WP devshot elementor kit get | json 'json_encode($d["settings"]["custom_colors"] ?? [])')" "$colors"

live="$($WP post list --post_type=page --meta_key=_elementor_edit_mode --meta_value=builder --post__not_in="$page" --field=ID --posts_per_page=1)"
if [ -n "$live" ]; then
  $WP devshot elementor dump "$live" >/dev/null && ok "dump of live page $live (read only)" || bad "dump of live page $live"
fi

rm -rf "$tmp"
[ "$fails" -eq 0 ] && echo "devshot elementor check: all passed" || echo "devshot elementor check: $fails failed" >&2
[ "$fails" -eq 0 ]
