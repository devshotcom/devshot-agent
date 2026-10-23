<?php
/**
 * Plugin Name: DevShot Elementor CLI
 * Description: `wp devshot elementor` — read and change Elementor pages through Elementor's own document API (spec 459).
 *
 * Studio's agent used to edit Elementor pages by writing `_elementor_data`
 * with `wp post meta update`: element ids by hand, 150+ controls per widget
 * from memory, nothing validated, the CSS cache left stale. This command is
 * the one way it changes a page now. Every write goes through
 * Document::save() (revisions, sanitising, hooks), new element ids are made
 * here, settings are checked against the widget's registered controls, and
 * Elementor's CSS cache is cleared after each save.
 *
 * Output is JSON on stdout. Exit codes:
 *   1 Elementor is not usable        2 bad arguments or JSON
 *   3 post, element or widget unknown 4 validation failed (nothing saved)
 *   5 Elementor refused the save
 */

if (!defined('ABSPATH') || !defined('WP_CLI') || !WP_CLI) {
  return;
}

final class DevShot_Elementor_Command {
  const EXIT_NO_ELEMENTOR = 1;
  const EXIT_USAGE = 2;
  const EXIT_NOT_FOUND = 3;
  const EXIT_INVALID = 4;
  const EXIT_SAVE = 5;

  // Control types that only lay out the editor panel and hold no value.
  const LAYOUT_CONTROLS = ['section', 'tab', 'tabs', 'divider', 'heading', 'raw_html', 'alert', 'notice', 'button', 'deprecated_notice'];
  // Control types whose value must be one of the control's options.
  const OPTION_CONTROLS = ['select', 'choose'];

  /**
   * Print an Elementor page as a compact element tree.
   *
   * ## OPTIONS
   *
   * <post>
   * : Post or page ID.
   *
   * [--id=<element>]
   * : Only this element and its children.
   *
   * [--pretty]
   * : Indent the JSON.
   *
   * ## EXAMPLES
   *
   *     wp devshot elementor dump 42
   *     wp devshot elementor dump 42 --id=3f2a9c1
   */
  public function dump($args, $assoc) {
    $document = $this->document($args);
    $elements = $document->get_elements_data();
    if (isset($assoc['id'])) {
      $found = $this->find($elements, (string) $assoc['id']);
      if (!$found) {
        $this->fail("element {$assoc['id']} is not on post {$args[0]}", self::EXIT_NOT_FOUND);
      }
      $this->out($this->compact($found['element']), $assoc);
      return;
    }
    $this->out([
      'post' => (int) $args[0],
      'title' => get_the_title((int) $args[0]),
      'elements' => array_map([$this, 'compact'], $elements),
    ], $assoc);
  }

  /**
   * List the registered widgets, the project's own included.
   *
   * ## OPTIONS
   *
   * [--search=<text>]
   * : Only widgets whose name or title contains the text.
   *
   * [--pretty]
   * : Indent the JSON.
   */
  public function widgets($args, $assoc) {
    $this->elementor();
    $search = isset($assoc['search']) ? strtolower((string) $assoc['search']) : '';
    $list = [];
    foreach (\Elementor\Plugin::$instance->widgets_manager->get_widget_types() as $name => $widget) {
      $title = (string) $widget->get_title();
      if ($search !== '' && strpos(strtolower($name . ' ' . $title), $search) === false) {
        continue;
      }
      $list[] = [
        'name' => $name,
        'title' => $title,
        'categories' => array_values((array) $widget->get_categories()),
        'class' => get_class($widget),
      ];
    }
    $this->out(['widgets' => $list], $assoc);
  }

  /**
   * Show one widget's (or element type's) controls: type, default, options,
   * responsive variants.
   *
   * ## OPTIONS
   *
   * <name>
   * : Widget name (heading, image, tfk-termine …) or element type (container, section, column).
   *
   * [--pretty]
   * : Indent the JSON.
   */
  public function widget($args, $assoc) {
    $this->elementor();
    $name = (string) ($args[0] ?? '');
    $type = $this->type_by_name($name);
    if (!$type) {
      $this->fail("no widget or element type named \"{$name}\" (wp devshot elementor widgets lists them)", self::EXIT_NOT_FOUND);
    }
    if (method_exists($type, 'get_props_schema')) {
      $this->out(['name' => $name, 'title' => (string) $type->get_title(), 'atomic' => true, 'props' => $type::get_props_schema()], $assoc);
      return;
    }
    $controls = [];
    $variants = [];
    $section = null;
    $all = $this->controls($type);
    foreach ($all as $id => $control) {
      $kind = $control['type'] ?? '';
      if ($kind === 'section') {
        $section = $id;
      }
      if (in_array($kind, self::LAYOUT_CONTROLS, true)) {
        continue;
      }
      if (!empty($control['parent']) && isset($control['responsive'])) {
        // Each device variant names the next larger one as parent
        // (_mobile → _tablet → base); list them all under the base control.
        $root = $control['parent'];
        while (!empty($all[$root]['parent'])) {
          $root = $all[$root]['parent'];
        }
        $variants[$root][] = $id;
        continue;
      }
      $entry = ['name' => $id, 'type' => $kind];
      if (isset($control['label']) && $control['label'] !== '') {
        $entry['label'] = wp_strip_all_tags((string) $control['label']);
      }
      if (array_key_exists('default', $control) && $control['default'] !== '' && $control['default'] !== null && $control['default'] !== []) {
        $entry['default'] = $control['default'];
      }
      if (!empty($control['options']) && is_array($control['options'])) {
        $entry['options'] = in_array($kind, self::OPTION_CONTROLS, true) ? array_map('strval', array_keys($control['options'])) : $control['options'];
      }
      if (!empty($control['condition'])) {
        $entry['condition'] = $control['condition'];
      }
      if ($section !== null) {
        $entry['section'] = $section;
      }
      $controls[$id] = $entry;
    }
    foreach ($variants as $parent => $names) {
      if (isset($controls[$parent])) {
        $controls[$parent]['responsive'] = $names;
      }
    }
    $this->out(['name' => $name, 'title' => (string) $type->get_title(), 'controls' => array_values($controls)], $assoc);
  }

  /**
   * Replace a page's whole element tree.
   *
   * Elements without an id get a new one; widget and element types must be
   * registered. Turns the post into an Elementor page if it is not one.
   *
   * ## OPTIONS
   *
   * <post>
   * : Post or page ID.
   *
   * --file=<path>
   * : JSON: an array of elements, or {"elements": [...]} (what dump prints).
   */
  public function apply($args, $assoc) {
    $document = $this->document($args, false);
    $json = $this->read_json_file($assoc);
    $elements = isset($json['elements']) && is_array($json['elements']) ? $json['elements'] : $json;
    if (!is_array($elements) || !$this->is_list($elements)) {
      $this->fail('--file must hold an array of elements or {"elements": [...]}', self::EXIT_USAGE);
    }
    $seen = [];
    $elements = $this->prepare($elements, false, $seen);
    $this->save($document, $elements, ['post' => (int) $args[0], 'elements' => count($elements)]);
  }

  /**
   * Change settings of one element.
   *
   * ## OPTIONS
   *
   * <post>
   * : Post or page ID.
   *
   * --id=<element>
   * : Element id (from dump).
   *
   * --set=<json>
   * : Settings to merge, e.g. '{"title":"Neu","title_color":"#c00"}'. null removes a setting.
   */
  public function patch($args, $assoc) {
    $document = $this->document($args);
    $id = $this->required($assoc, 'id');
    $set = json_decode($this->required($assoc, 'set'), true);
    if (!is_array($set) || ($set !== [] && $this->is_list($set))) {
      $this->fail('--set must be a JSON object of settings', self::EXIT_USAGE);
    }
    $elements = $document->get_elements_data();
    $found = $this->find($elements, $id);
    if (!$found) {
      $this->fail("element {$id} is not on post {$args[0]}", self::EXIT_NOT_FOUND);
    }
    $element = $found['element'];
    $this->validate_settings($element, $set);
    $settings = isset($element['settings']) && is_array($element['settings']) ? $element['settings'] : [];
    $before = [];
    foreach ($set as $key => $value) {
      $before[$key] = $settings[$key] ?? null;
      if ($value === null) {
        unset($settings[$key]);
      } else {
        $settings[$key] = $value;
      }
    }
    $element['settings'] = $settings;
    $elements = $this->replace_at($elements, $found['path'], $element);
    $this->save($document, $elements, ['post' => (int) $args[0], 'id' => $id, 'before' => $before, 'after' => $set]);
  }

  /**
   * Insert new elements into a page. Every inserted element gets a new id.
   *
   * ## OPTIONS
   *
   * <post>
   * : Post or page ID.
   *
   * --parent=<element>
   * : Id of the container/section/column to insert into, or "root" for the top level.
   *
   * [--after=<element>]
   * : Insert after this sibling; without it the elements are appended.
   *
   * --file=<path>
   * : JSON: one element or an array of elements.
   */
  public function insert($args, $assoc) {
    $document = $this->document($args);
    $parent = $this->required($assoc, 'parent');
    $json = $this->read_json_file($assoc);
    $new = $this->is_list($json) ? $json : [$json];
    $seen = [];
    $elements = $document->get_elements_data();
    $this->collect_ids($elements, $seen);
    $new = $this->prepare($new, true, $seen);
    $ids = array_map(function ($element) { return $element['id']; }, $new);

    if ($parent === 'root') {
      $elements = $this->splice($elements, $new, $assoc['after'] ?? null, 'root');
    } else {
      $found = $this->find($elements, $parent);
      if (!$found) {
        $this->fail("parent {$parent} is not on post {$args[0]}", self::EXIT_NOT_FOUND);
      }
      $target = $found['element'];
      if (($target['elType'] ?? '') === 'widget') {
        $this->fail("parent {$parent} is a widget; insert into a container, section or column", self::EXIT_INVALID);
      }
      $target['elements'] = $this->splice($target['elements'] ?? [], $new, $assoc['after'] ?? null, $parent);
      $elements = $this->replace_at($elements, $found['path'], $target);
    }
    $this->save($document, $elements, ['post' => (int) $args[0], 'parent' => $parent, 'inserted' => $ids]);
  }

  /**
   * Remove one element (and its children) from a page.
   *
   * ## OPTIONS
   *
   * <post>
   * : Post or page ID.
   *
   * --id=<element>
   * : Element id (from dump).
   */
  public function remove($args, $assoc) {
    $document = $this->document($args);
    $id = $this->required($assoc, 'id');
    $elements = $document->get_elements_data();
    $found = $this->find($elements, $id);
    if (!$found) {
      $this->fail("element {$id} is not on post {$args[0]}", self::EXIT_NOT_FOUND);
    }
    $elements = $this->replace_at($elements, $found['path'], null);
    $this->save($document, $elements, ['post' => (int) $args[0], 'removed' => $id]);
  }

  /**
   * Read or change the global settings of the active kit (colors, typography).
   *
   * ## OPTIONS
   *
   * <action>
   * : get or set
   * ---
   * options:
   *   - get
   *   - set
   * ---
   *
   * [--set=<json>]
   * : For set: top-level kit settings to replace, e.g. '{"system_colors":[...]}'. null removes one.
   *
   * [--all]
   * : For get: every kit setting, not just colors and typography.
   *
   * [--pretty]
   * : Indent the JSON.
   */
  public function kit($args, $assoc) {
    $this->elementor();
    $kit = \Elementor\Plugin::$instance->kits_manager->get_active_kit();
    if (!$kit || !$kit->get_main_id()) {
      $this->fail('there is no active Elementor kit', self::EXIT_NOT_FOUND);
    }
    $settings = $kit->get_settings();
    $settings = is_array($settings) ? $settings : [];
    $action = $args[0] ?? '';
    if ($action === 'get') {
      $keys = ['system_colors', 'custom_colors', 'system_typography', 'custom_typography'];
      $out = isset($assoc['all']) ? $settings : array_intersect_key($settings, array_flip($keys));
      $this->out(['kit' => (int) $kit->get_main_id(), 'settings' => $out], $assoc);
      return;
    }
    if ($action !== 'set') {
      $this->fail('kit takes get or set', self::EXIT_USAGE);
    }
    $set = json_decode($this->required($assoc, 'set'), true);
    if (!is_array($set) || $set === [] || $this->is_list($set)) {
      $this->fail('--set must be a JSON object of kit settings', self::EXIT_USAGE);
    }
    $known = $kit->get_controls();
    $unknown = array_values(array_diff(array_keys($set), array_keys($known)));
    if ($unknown) {
      $this->fail('unknown kit settings: ' . implode(', ', $unknown), self::EXIT_INVALID);
    }
    foreach ($set as $key => $value) {
      if ($value === null) {
        unset($settings[$key]);
      } else {
        $settings[$key] = $value;
      }
    }
    $this->as_editor((int) $kit->get_main_id());
    if (!$kit->save(['settings' => $settings])) {
      $this->fail('Elementor refused to save the kit', self::EXIT_SAVE);
    }
    \Elementor\Plugin::$instance->files_manager->clear_cache();
    $this->out(['ok' => true, 'kit' => (int) $kit->get_main_id(), 'changed' => array_keys($set), 'css_flushed' => true], $assoc);
  }

  // ── helpers ────────────────────────────────────────────────────────────

  private function elementor() {
    if (!class_exists('\Elementor\Plugin') || !isset(\Elementor\Plugin::$instance)) {
      $this->fail('Elementor is not active on this site (wp plugin activate elementor)', self::EXIT_NO_ELEMENTOR);
    }
    // Outside wp-admin Elementor registers controls without labels and
    // options and leaves the style controls out (Performance::
    // should_optimize_controls, decided once per request). The command reads
    // and saves like the editor does, which runs in wp-admin.
    if (!defined('WP_ADMIN')) {
      define('WP_ADMIN', true);
    }
    if (class_exists('\Elementor\Core\Frontend\Performance') && \Elementor\Core\Frontend\Performance::should_optimize_controls()) {
      $this->fail('Elementor already loaded its trimmed frontend controls in this process; run with --context=admin', self::EXIT_NO_ELEMENTOR);
    }
  }

  private function document($args, $must_be_elementor = true) {
    $this->elementor();
    $post_id = isset($args[0]) ? (int) $args[0] : 0;
    if ($post_id <= 0 || !get_post($post_id)) {
      $this->fail('no post with id ' . ($args[0] ?? '(missing)'), self::EXIT_NOT_FOUND);
    }
    $document = \Elementor\Plugin::$instance->documents->get($post_id, false);
    if (!$document) {
      $this->fail("post {$post_id} has no Elementor document (its post type is not supported by Elementor)", self::EXIT_NOT_FOUND);
    }
    if ($must_be_elementor && !$document->is_built_with_elementor()) {
      $this->fail("post {$post_id} is not built with Elementor; create its tree with apply", self::EXIT_NOT_FOUND);
    }
    return $document;
  }

  private function type_by_name($name) {
    if ($name === '') {
      return null;
    }
    $widget = \Elementor\Plugin::$instance->widgets_manager->get_widget_types($name);
    if ($widget) {
      return $widget;
    }
    if ($name === 'widget') {
      return null;
    }
    return \Elementor\Plugin::$instance->elements_manager->get_element_types($name);
  }

  private function type_of(array $element) {
    $el_type = (string) ($element['elType'] ?? '');
    return $el_type === 'widget'
      ? \Elementor\Plugin::$instance->widgets_manager->get_widget_types((string) ($element['widgetType'] ?? ''))
      : $this->type_by_name($el_type);
  }

  // The type's controls, with the device variants Elementor only creates at
  // render time (responsive_control_duplication_mode "on-runtime": align has
  // no registered align_tablet, yet align_tablet is a valid setting). One
  // entry per active breakpoint, without a default.
  private function controls($type) {
    $controls = $type->get_controls();
    $devices = array_keys(\Elementor\Plugin::$instance->breakpoints->get_active_breakpoints());
    foreach ($controls as $id => $control) {
      if (!isset($control['responsive']) || !empty($control['parent'])) {
        continue;
      }
      foreach ($devices as $device) {
        if (!isset($controls["{$id}_{$device}"])) {
          $variant = $control;
          unset($variant['default']);
          $controls["{$id}_{$device}"] = ['parent' => $id, 'responsive' => ['max' => $device]] + $variant;
        }
      }
    }
    return $controls;
  }

  // A tree node without the settings that equal their control's default.
  private function compact(array $element) {
    $type = $this->type_of($element);
    $settings = isset($element['settings']) && is_array($element['settings']) ? $element['settings'] : [];
    if ($type && !method_exists($type, 'get_props_schema')) {
      $controls = $this->controls($type);
      foreach ($settings as $key => $value) {
        if (isset($controls[$key]) && array_key_exists('default', $controls[$key]) && $controls[$key]['default'] == $value) {
          unset($settings[$key]);
        }
      }
    }
    $node = ['id' => (string) ($element['id'] ?? ''), 'elType' => (string) ($element['elType'] ?? '')];
    if (!empty($element['widgetType'])) {
      $node['widgetType'] = (string) $element['widgetType'];
    }
    $classes = trim((string) ($settings['_css_classes'] ?? $settings['css_classes'] ?? ''));
    if ($classes !== '') {
      $node['css_classes'] = $classes;
    }
    if (!$type) {
      $node['unregistered'] = true;
    }
    if ($settings) {
      $node['settings'] = $settings;
    }
    if (!empty($element['elements'])) {
      $node['elements'] = array_map([$this, 'compact'], $element['elements']);
    }
    return $node;
  }

  // Check types and ids of new or replaced elements and give ids where
  // needed. $fresh: every element gets a new id (insert).
  private function prepare(array $elements, $fresh, array &$seen) {
    $out = [];
    foreach ($elements as $element) {
      if (!is_array($element) || empty($element['elType'])) {
        $this->fail('every element needs an elType (container, section, column, widget …)', self::EXIT_INVALID);
      }
      if ($element['elType'] === 'widget' && empty($element['widgetType'])) {
        $this->fail('a widget element needs a widgetType', self::EXIT_INVALID);
      }
      $label = $element['elType'] === 'widget' ? "widget {$element['widgetType']}" : "element type {$element['elType']}";
      if (!$this->type_of($element)) {
        $this->fail("{$label} is not registered (wp devshot elementor widgets lists them)", self::EXIT_INVALID);
      }
      if ($fresh || empty($element['id'])) {
        $element['id'] = $this->new_id($seen);
      } else {
        $id = (string) $element['id'];
        if (!preg_match('/^[0-9a-z]{1,16}$/', $id)) {
          $this->fail("element id \"{$id}\" is not an Elementor id; leave id out to get a new one", self::EXIT_INVALID);
        }
        if (isset($seen[$id])) {
          $this->fail("element id {$id} appears twice", self::EXIT_INVALID);
        }
        $seen[$id] = true;
      }
      $settings = isset($element['settings']) && is_array($element['settings']) ? $element['settings'] : [];
      if ($fresh && $settings) {
        $this->validate_settings($element, $settings);
      }
      $element['settings'] = $settings;
      $element['elements'] = $this->prepare(isset($element['elements']) && is_array($element['elements']) ? $element['elements'] : [], $fresh, $seen);
      if ($element['elType'] !== 'widget') {
        unset($element['widgetType']);
      }
      $element['isInner'] = !empty($element['isInner']);
      $out[] = $element;
    }
    return $out;
  }

  // Setting names must be controls (or props of an atomic widget); a select
  // or choose value must be one of its options. Elementor's own __globals__ /
  // __dynamic__ maps pass through.
  private function validate_settings(array $element, array $set) {
    $type = $this->type_of($element);
    $label = !empty($element['widgetType']) ? $element['widgetType'] : ($element['elType'] ?? '?');
    if (!$type) {
      $this->fail("{$label} is not registered; its settings cannot be checked", self::EXIT_INVALID);
    }
    $known = method_exists($type, 'get_props_schema') ? $type::get_props_schema() : $this->controls($type);
    $errors = [];
    foreach ($set as $key => $value) {
      if (strpos((string) $key, '__') === 0) {
        continue;
      }
      if (!isset($known[$key])) {
        $errors[] = "{$key} is not a setting of {$label}";
        continue;
      }
      $control = $known[$key];
      if (is_array($control) && in_array($control['type'] ?? '', self::OPTION_CONTROLS, true)
        && !empty($control['options']) && $value !== null && $value !== ''
        && !array_key_exists((string) $value, $control['options'])) {
        $errors[] = "{$key} must be one of: " . implode(', ', array_map('strval', array_keys($control['options'])));
      }
    }
    if ($errors) {
      $this->fail(implode('; ', $errors) . " (wp devshot elementor widget {$label} lists the settings)", self::EXIT_INVALID);
    }
  }

  private function new_id(array &$seen) {
    do {
      $id = substr(bin2hex(random_bytes(4)), 0, 7);
    } while (isset($seen[$id]));
    $seen[$id] = true;
    return $id;
  }

  private function collect_ids(array $elements, array &$seen) {
    foreach ($elements as $element) {
      if (!empty($element['id'])) {
        $seen[(string) $element['id']] = true;
      }
      $this->collect_ids($element['elements'] ?? [], $seen);
    }
  }

  // ['element' => …, 'path' => [index, index, …]] or null.
  private function find(array $elements, $id, array $path = []) {
    foreach ($elements as $index => $element) {
      if ((string) ($element['id'] ?? '') === $id) {
        return ['element' => $element, 'path' => array_merge($path, [$index])];
      }
      $hit = $this->find($element['elements'] ?? [], $id, array_merge($path, [$index]));
      if ($hit) {
        return $hit;
      }
    }
    return null;
  }

  // Replace the element at $path, or remove it when $element is null.
  private function replace_at(array $elements, array $path, $element) {
    $index = array_shift($path);
    if (!$path) {
      if ($element === null) {
        array_splice($elements, $index, 1);
      } else {
        $elements[$index] = $element;
      }
      return $elements;
    }
    $elements[$index]['elements'] = $this->replace_at($elements[$index]['elements'] ?? [], $path, $element);
    return $elements;
  }

  private function splice(array $siblings, array $new, $after, $parent) {
    if ($after === null) {
      return array_merge($siblings, $new);
    }
    foreach ($siblings as $index => $sibling) {
      if ((string) ($sibling['id'] ?? '') === (string) $after) {
        array_splice($siblings, $index + 1, 0, $new);
        return $siblings;
      }
    }
    $this->fail("--after {$after} is not a child of {$parent}", self::EXIT_NOT_FOUND);
  }

  private function save($document, array $elements, array $report) {
    $post_id = (int) $document->get_main_id();
    $this->as_editor($post_id);
    $document->set_is_built_with_elementor(true);
    if (!$document->save(['elements' => $elements])) {
      $this->fail("Elementor refused to save post {$post_id}", self::EXIT_SAVE);
    }
    \Elementor\Plugin::$instance->files_manager->clear_cache();
    $this->out(['ok' => true] + $report + ['css_flushed' => true], []);
  }

  // Document::save() checks the current user's edit rights; WP-CLI has no
  // user unless --user is given, so the command acts as the first
  // administrator.
  private function as_editor($post_id) {
    if (current_user_can('edit_post', $post_id)) {
      return;
    }
    $admins = get_users(['role' => 'administrator', 'number' => 1, 'orderby' => 'ID', 'fields' => 'ID']);
    if (!$admins) {
      $this->fail('no administrator account to save as; pass --user=<login>', self::EXIT_SAVE);
    }
    wp_set_current_user((int) $admins[0]);
  }

  private function read_json_file(array $assoc) {
    $file = $this->required($assoc, 'file');
    if (!is_readable($file)) {
      $this->fail("cannot read {$file}", self::EXIT_USAGE);
    }
    $json = json_decode((string) file_get_contents($file), true);
    if (!is_array($json)) {
      $this->fail("{$file} is not valid JSON: " . json_last_error_msg(), self::EXIT_USAGE);
    }
    return $json;
  }

  private function required(array $assoc, $key) {
    if (!isset($assoc[$key]) || $assoc[$key] === '' || $assoc[$key] === true) {
      $this->fail("--{$key} is required", self::EXIT_USAGE);
    }
    return (string) $assoc[$key];
  }

  private function is_list(array $value) {
    return $value === [] || array_keys($value) === range(0, count($value) - 1);
  }

  private function out($data, array $assoc) {
    $flags = JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | (isset($assoc['pretty']) ? JSON_PRETTY_PRINT : 0);
    WP_CLI::line(wp_json_encode($data, $flags));
  }

  private function fail($message, $code) {
    WP_CLI::error($message, $code);
  }
}

WP_CLI::add_command('devshot elementor', 'DevShot_Elementor_Command');
