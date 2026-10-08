# Menu Customizer for KOReader

A KOReader plugin that shows the **full menu hierarchy** of both the Reader and
the File Browser and lets you **disable, reorder and move** submenus and menu
items — and **disable** whole tabs — including items added by third‑party
plugins.

The plugin writes native KOReader `*_menu_order.lua` override files, so your
customizations are applied by KOReader's own menu sorter after a restart. No
core files are patched.

## Features

- **Human‑readable labels (main feature)** — the editor shows the real menu
  titles in the program's language instead of internal item ids (tab names come
  from a fixed list), so you always see the same names you see in the real menu.
- **Full hierarchy browser** — expand any tab or submenu and see every item it
  contains, including nested "inline" submenus that are not declared in the
  menu‑order tables.
- **Disable / enable items** — tap an item to toggle it on or off. Disabled
  items are removed from the real menu at runtime and from the generated order
  file.
- **Bulk toggle with long‑tap** — long‑tap a submenu or tab to disable/enable
  the entry together with all of its children.
- **Reorder items** — a sort widget lets you drag items into any order within a
  menu or tab.
- **Move items between menus** — move an item from one tab/submenu to another;
  the move is remembered even after a restart. Targets are limited to tabs and
  submenus that are part of the menu structure — items cannot be moved into
  nested "inline" submenus.
- **Third‑party plugin support** — new items registered by other plugins *inside
  existing tabs and submenus* are discovered automatically and become
  customizable. See the note in Usage.
- **No more `NEW:` orphans** — menu items that appear *after* you already
  generated the order file (e.g. a plugin you installed or updated later) are
  picked up automatically and inserted into their correct parent menu on the
  next start, instead of being left as orphans prefixed with `NEW:` at the
  bottom of the first tab.
- **Unavailable‑item handling** — items that do not exist on the current device
  or build are marked, and are **hidden in the editor by default** so the list
  stays clean and only shows items that are actually available; this can be
  toggled off at any time.
- **Safe, minimal writes** — settings and order files are only written when
  their content actually changed.
- **Automatic restart** — KOReader is restarted automatically after applying or
  resetting changes when the programmatic restart is available.

## Requirements

- KOReader (any recent version with `ui/menusorter.lua`).
- No additional dependencies.

## Installation

1. Download or clone this repository.
2. Copy the `menucustomizer.koplugin` folder into KOReader's `plugins`
   directory:

   ```
   koreader/plugins/menucustomizer.koplugin/
   ├── _meta.lua
   ├── main.lua
   └── README.md
   ```

3. Restart KOReader.

## Usage

> [!IMPORTANT]
> - **KOReader will restart automatically** when you apply or reset changes
>   (both single‑mode and "Apply all changes"). Save any work first; if a
>   programmatic restart is not available, the plugin asks you to restart
>   manually instead.
> - **Press "Refresh translations cache" once in each mode** (Reader and File
>   browser) so menu item names are cached for that mode. Readable names are the
>   main feature of this plugin: if a mode's cache was never filled, its items
>   may appear as internal ids or with "(needs verification)". Opening either
>   hierarchy while in a mode also refreshes that mode's cache automatically.

> [!NOTE]
> **Third‑party tabs are not supported.** The plugin can customize items that
> third‑party plugins add *inside* existing tabs and submenus, but it does not
> handle new **top‑level tabs** added by third‑party plugins: such tabs are
> neither discovered nor editable here.

Open the menu and go to **Tools → More tools → Menu customizer** (the entry is
added to the `more_tools` submenu of the Tools tab in both modes).

The top-level **Menu customizer** menu contains:

| Menu entry | What it does |
|---|---|
| **Reader menu** | Opens the full Reader menu hierarchy for editing. |
| **File browser menu** | Opens the full File Browser menu hierarchy for editing. |
| **Refresh translations cache** | Re‑scans the current mode and updates the cached item labels. |
| **Hide unavailable items** | Toggles whether items that are unavailable in a mode are hidden in the editor. |
| **Apply all changes** | Generates the menu order files for *both* modes and restarts KOReader. |
| **Reset everything to defaults** | Clears all plugin settings, removes the generated files and restarts. |
| **Created files info** | Shows whether the generated order files exist and where they are. |

Inside the **Reader menu** / **File browser menu** hierarchy:

- **Tap** a tab, submenu or item to toggle it (a check mark means enabled).
- **Long‑tap** a tab or submenu to toggle it and all of its children at once.
- **Reorder / move items** opens a chooser: pick a tab or submenu to reorder its
  items with a sort widget; long‑tap an item there (or use the widget menu) to
  move it to another tab/menu.
- Use **Apply changes (restart required)** at the bottom of each hierarchy to
  write the order file for that mode and restart.

## How it works

The plugin hooks `MenuSorter:mergeAndSort` to:

1. Discover custom items registered by third‑party plugins and remember their
   parent menu.
2. Filter out disabled items from the live `tab_item_table` (including items in
   inline submenus that have no stable `id`).
3. Generate `reader_menu_order.lua` / `filemanager_menu_order.lua` in KOReader's
   settings directory, which `MenuSorter` picks up on the next start.

Menu labels for items that are not present in the currently active mode are
served from a small persistent per‑mode label cache, so the editor still shows
readable names instead of raw ids.

## Files created

| File | Location | Purpose |
|---|---|---|
| `menu_customizer.lua` | KOReader settings dir | Plugin settings (disabled sets, ordering, label cache). |
| `menu_customizer_inline.lua` | KOReader settings dir | Cached nested inline submenus (loaded lazily). |
| `reader_menu_order.lua` | KOReader settings dir | Generated Reader menu order override. |
| `filemanager_menu_order.lua` | KOReader settings dir | Generated File Browser menu order override. |

## Localization

The UI follows KOReader's language setting
(`G_reader_settings:readSetting("language")`). Any locale starting with `uk` is
shown in Ukrainian; every other locale falls back to English.

## Notes and compatibility

- The plugin does **not** modify KOReader core files; it only monkey‑patches
  `MenuSorter:mergeAndSort` at runtime and generates standard order‑override
  files.
- Because it hooks an internal KOReader module, a future KOReader release may
  require updates. Many risky operations (file reads/writes, optional callbacks)
  are wrapped in `pcall`, but the hook itself is not — a future core change may
  therefore break the menu until the plugin is updated.
- If a third‑party plugin changes its menu item ids between versions, stale
  entries are pruned automatically the next time the menu is built.

## Uninstall

1. Open **Menu customizer → Reset everything to defaults** to remove the settings
   and generated order files.
2. Delete the `menucustomizer.koplugin` folder.
3. Restart KOReader.

## Disclaimer

This plugin and its documentation were generated by AI. The plugin **was tested
by the developer** on a real Kindle device, but it is still provided "as is":
review the source code carefully before installing, test it on your own device,
and keep a backup of your KOReader settings.
