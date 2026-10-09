--[[--
Menu Customizer plugin for KOReader.

Displays the full menu hierarchy (tabs, submenus, items) for Reader and
File Manager modes and allows disabling individual entries.  Generates
custom reader_menu_order.lua / filemanager_menu_order.lua in the KOReader
settings directory so that MenuSorter picks them up on restart.

@module koplugin.MenuCustomizer
--]]

-- Version 1.1: додано підтримку та відображення вкладених (inline) підменю, рекурсивний обхід та рантайм-фільтрацію відключених підпунктів.
-- Version 1.2: виправлено рантайм-фільтрацію пунктів без id у вкладених (inline) підменю: фільтр тепер обходить кожну вкладку окремо, а ключі пунктів з text_func рахуються так само, як при скануванні.
-- Version 1.3: inline-кеш у редакторі меню більше не перезаписується відфільтрованим "живим" меню - новий скан лише доповнює кеш, тож приховані пункти без id лишаються видимими у редакторі і їх можна увімкнути назад.
-- Version 1.4: прибирання розділювачів у filterItems більше не видаляє реальні пункти з прапорцем separator=true (виправлено зникнення підменю coverbrowser "Параметри мозаїчного і детального списків").
-- Version 1.5: стабільні ключі inline-пунктів без статичного тексту (text_func): у ключ йде позиція в списку (#i), а не динамічне значення - прихований пункт більше не "оживає" після зміни значення.
-- Version 1.6: списки-вибірники (вкладка/меню та куди перемістити пункт) відображаються без заокруглених кутів (is_popout=false).
-- Version 1.7: додано логування в консоль моментів запису у файл (flush) для налаштувань та файлів порядку меню.
-- Version 1.8: saveSettings тепер серіалізує вміст у пам'яті й пропускає запис (без flush), якщо файл не змінився.
-- Version 1.9: split the inline-submenu caches into a separate, lazily loaded file; removed the per-session inline scan from the MenuSorter hook; added an in-memory content cache to skip redundant settings writes.
-- Version 1.10: auto-restart KOReader after applying or resetting menu changes (falls back to the manual-restart message when a programmatic restart is unavailable).
-- Version 1.11: localized all user-visible strings (en/uk via tr/trn) instead of gettext _(); fixes Ukrainian text showing under an English KOReader locale.
-- Version 1.12: renamed the English menu label from "Menu settings" to "Menu customizer".
-- Version 1.13: preserve top-level tabs added at runtime by third-party plugins (custom_tabs_*). They are discovered from the live order table, persisted (id -> label, id -> predecessor) and re-injected into KOMenu:menu_buttons in the generated override file so they are not dropped. The tab contents are intentionally left untouched: the override never emits the tab's item-list key.
-- Version 1.14: custom-tab items are editable again (children are discovered under the tab and shown in its submenu). Keeps the empty-tab safeguard (the tab's item-list key is emitted only when a non-empty child list was discovered) and stops pruning the disable flag of custom-tab items, so a disabled child stays disabled across restarts.

local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local SortWidget = require("ui/widget/sortwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = require("ffi/util").template

-- ── Localization (en/uk) ────────────────────────────────────────────
-- Language is read from G_reader_settings:readSetting("language"); any
-- locale other than "uk*" falls back to English.
local function is_uk_language()
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    return type(lang) == "string" and lang:sub(1, 2) == "uk"
end

--- Pick the English or Ukrainian variant of a string.
local function tr(en, uk)
    if is_uk_language() then
        return uk or en
    end
    return en
end

--- Ukrainian-aware plural selection (kept for plural strings).
local function trn(n, en1, enN, uk1, ukFew, ukMany)
    if is_uk_language() then
        local n10 = n % 10
        local n100 = n % 100
        if n10 == 1 and n100 ~= 11 then
            return uk1
        elseif n10 >= 2 and n10 <= 4 and (n100 < 12 or n100 > 14) then
            return ukFew
        else
            return ukMany
        end
    end
    return (n == 1) and en1 or enN
end


local MenuCustomizer = WidgetContainer:extend{
    name = "menucustomizer",
    is_doc_only = false,
}

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/menu_customizer.lua"
-- Nested (inline) submenus live in their own file: they are only needed while
-- the plugin's own editor menu is open, so keeping them out of the main
-- settings file removes their parse/serialize cost from the first top-level
-- menu open after a restart (they used to be ~380 KB of a ~464 KB file).
local INLINE_SETTINGS_FILE = DataStorage:getSettingsDir() .. "/menu_customizer_inline.lua"
local SEPARATOR_ID  = "----------------------------"

-- ────────────────────────────────────────────────────────────────────
-- Helpers
-- ────────────────────────────────────────────────────────────────────

--- Deep-copy a table (one level of arrays is enough here).
local function shallowCopyArray(t)
    local copy = {}
    for i, v in ipairs(t) do
        copy[i] = v
    end
    return copy
end

--- Ids of top-level tabs (KOMenu:menu_buttons entries). Kept in sync with
--- ENGLISH_SOURCES' tab section. Tabs never belong in the text caches (see
--- resolveTabLabel), so we strip any leftover entries an older version of
--- this plugin may have tombstoned there.
local TAB_IDS = {
    navi = true, typeset = true, setting = true, tools = true,
    search = true, filemanager = true, main = true, plus_menu = true,
    filemanager_settings = true,
}

local function stripTabEntries(cache)
    if not cache then return end
    for tab_id in pairs(TAB_IDS) do
        cache[tab_id] = nil
    end
end

--- In-memory cache of the currently loaded settings table. There must be
--- only ONE live settings table per session: every menu builder and every
--- callback closure needs to read/write the same object, otherwise two
--- independently-loaded copies can go stale relative to each other and a
--- save from one can silently overwrite a change made through the other.
--- Use getSettings() (below) everywhere instead of calling
--- loadSettingsFromDisk() directly.
local _settings_cache = nil

--- In-memory cache of the dedicated inline-submenu file (INLINE_SETTINGS_FILE).
--- Loaded lazily by getInlineMenus() and written by saveInlineMenus(); kept out
--- of the main settings table so it never takes part in the first-menu-open path.
local _inline_cache = nil

--- Legacy inline-submenu arrays embedded in the main settings file (pre-1.9
--- format). Consumed once by migrateInlineMenus() when splitting the file.
local _legacy_inline_menus = nil

--- Serialized content last known to be on disk, used to skip redundant writes
--- (and the associated file re-read) when nothing actually changed.
local _last_saved_content = nil
local _last_saved_inline_content = nil

--- Read plugin settings from disk (disabled items sets). Internal —
--- callers should use getSettings() instead so the file is only actually
--- read once per session.
--- Migrate old custom_items_* (flat hash) to custom_items_order_*
--- (ordered arrays grouped by parent). Called once when loading settings
--- that lack the new ordered format.
local function migrateCustomItemsOrder(custom_items)
    local order_by_parent = {}
    -- Collect ids grouped by parent
    local ids_by_parent = {}
    for id, parent in pairs(custom_items) do
        if not ids_by_parent[parent] then
            ids_by_parent[parent] = {}
        end
        table.insert(ids_by_parent[parent], id)
    end
    -- Sort ids alphabetically within each parent for initial determinism
    for parent, ids in pairs(ids_by_parent) do
        table.sort(ids)
        order_by_parent[parent] = ids
    end
    return order_by_parent
end

local function loadSettingsFromDisk()
    if lfs.attributes(SETTINGS_FILE, "mode") then
        local ok, data = pcall(dofile, SETTINGS_FILE)
        if ok and type(data) == "table" then
            data.text_cache_reader = data.text_cache_reader or {}
            data.text_cache_filemanager = data.text_cache_filemanager or {}
            data.custom_items_reader = data.custom_items_reader or {}
            data.custom_items_filemanager = data.custom_items_filemanager or {}
            data.items_order_reader = data.items_order_reader or {}
            data.items_order_filemanager = data.items_order_filemanager or {}
            data.custom_tabs_reader = data.custom_tabs_reader or {}
            data.custom_tabs_filemanager = data.custom_tabs_filemanager or {}
            data.custom_tabs_after_reader = data.custom_tabs_after_reader or {}
            data.custom_tabs_after_filemanager = data.custom_tabs_after_filemanager or {}
            -- Inline submenu caches moved to INLINE_SETTINGS_FILE in v1.9. Keep
            -- the legacy embedded arrays for a one-time migration, then drop
            -- them from the settings table so they are no longer serialized.
            _legacy_inline_menus = {
                reader = data.inline_menus_reader or {},
                filemanager = data.inline_menus_filemanager or {},
            }
            data.inline_menus_reader = nil
            data.inline_menus_filemanager = nil
            -- Migrate: build ordered arrays from flat hashes if absent
            if not data.custom_items_order_reader then
                data.custom_items_order_reader = migrateCustomItemsOrder(data.custom_items_reader)
            end
            if not data.custom_items_order_filemanager then
                data.custom_items_order_filemanager = migrateCustomItemsOrder(data.custom_items_filemanager)
            end
            if data.hide_unavailable == nil then
                data.hide_unavailable = true
            end
            stripTabEntries(data.text_cache_reader)
            stripTabEntries(data.text_cache_filemanager)
            return data
        end
    end
    return {
        reader_disabled = {},
        filemanager_disabled = {},
        reader_tabs_disabled = {},
        filemanager_tabs_disabled = {},
        text_cache_reader = {},
        text_cache_filemanager = {},
        custom_items_reader = {},
        custom_items_filemanager = {},
        custom_items_order_reader = {},
        custom_items_order_filemanager = {},
        items_order_reader = {},
        items_order_filemanager = {},
        custom_tabs_reader = {},
        custom_tabs_filemanager = {},
        custom_tabs_after_reader = {},
        custom_tabs_after_filemanager = {},
        hide_unavailable = true,
    }
end

--- Read the dedicated inline-submenus file, falling back to the legacy arrays
--- carried over from the main settings file (see loadSettingsFromDisk).
local function loadInlineMenusFromDisk()
    if lfs.attributes(INLINE_SETTINGS_FILE, "mode") then
        local ok, data = pcall(dofile, INLINE_SETTINGS_FILE)
        if ok and type(data) == "table" then
            return {
                reader = data.reader or {},
                filemanager = data.filemanager or {},
            }
        end
    end
    if _legacy_inline_menus then
        return {
            reader = _legacy_inline_menus.reader or {},
            filemanager = _legacy_inline_menus.filemanager or {},
        }
    end
    return { reader = {}, filemanager = {} }
end

--- Get the shared inline-submenus cache, loading it from disk on first use.
--- This is the ONLY supported way to reach inline submenus; do not read
--- settings.inline_menus_* (removed in v1.9).
local function getInlineMenus()
    if not _inline_cache then
        _inline_cache = loadInlineMenusFromDisk()
    end
    return _inline_cache
end

--- Serialize the inline-submenus cache into a standalone Lua file.
local function serializeInlineMenus(inline)
    local buf = {}
    local function out(s)
        table.insert(buf, s)
    end

    local function writeEntry(entry, indent)
        out(indent .. "{\n")
        if entry.id then
            out(string.format("%s    id = %q,\n", indent, entry.id))
        end
        if entry.key then
            out(string.format("%s    key = %q,\n", indent, entry.key))
        end
        if entry.text then
            out(string.format("%s    text = %q,\n", indent, entry.text))
        end
        if entry.is_submenu then
            out(string.format("%s    is_submenu = true,\n", indent))
        end
        if entry.children and #entry.children > 0 then
            out(string.format("%s    children = {\n", indent))
            for _, child in ipairs(entry.children) do
                writeEntry(child, indent .. "        ")
            end
            out(string.format("%s    },\n", indent))
        end
        out(indent .. "},\n")
    end

    local function writeMap(name, tbl)
        out("    " .. name .. " = {\n")
        if tbl then
            local keys = {}
            for k in pairs(tbl) do
                table.insert(keys, k)
            end
            table.sort(keys)
            for _, k in ipairs(keys) do
                local item = tbl[k]
                out(string.format("        [%q] = {\n", k))
                if item.id then
                    out(string.format("            id = %q,\n", item.id))
                end
                if item.key then
                    out(string.format("            key = %q,\n", item.key))
                end
                if item.text then
                    out(string.format("            text = %q,\n", item.text))
                end
                if item.children and #item.children > 0 then
                    out("            children = {\n")
                    for _, child in ipairs(item.children) do
                        writeEntry(child, "                ")
                    end
                    out("            },\n")
                end
                out("        },\n")
            end
        end
        out("    },\n")
    end

    out("return {\n")
    writeMap("reader", inline.reader)
    writeMap("filemanager", inline.filemanager)
    out("}\n")
    return table.concat(buf)
end

--- Save the inline-submenus cache, skipping both the file re-read and the write
--- when the serialized content is unchanged.
local function saveInlineMenus()
    local inline = _inline_cache or { reader = {}, filemanager = {} }
    local content = serializeInlineMenus(inline)

    if content == _last_saved_inline_content and lfs.attributes(INLINE_SETTINGS_FILE, "mode") then
        logger.info("MenuCustomizer: no changes, skip writing", INLINE_SETTINGS_FILE)
        return
    end

    if lfs.attributes(INLINE_SETTINGS_FILE, "mode") and not _last_saved_inline_content then
        local f_in = io.open(INLINE_SETTINGS_FILE, "r")
        if f_in then
            local old_content = f_in:read("*all")
            f_in:close()
            if old_content == content then
                _last_saved_inline_content = content
                logger.info("MenuCustomizer: no changes, skip writing", INLINE_SETTINGS_FILE)
                return
            end
        end
    end

    local f = io.open(INLINE_SETTINGS_FILE, "w")
    if not f then
        logger.err("MenuCustomizer: cannot write", INLINE_SETTINGS_FILE)
        return
    end
    f:write(content)
    f:flush()
    f:close()
    _last_saved_inline_content = content
    logger.info("MenuCustomizer: flushed inline menus to", INLINE_SETTINGS_FILE)
end

--- Save plugin settings. Also (re-)establishes this table as the shared
--- in-memory cache, so any earlier/other reference to the old cached
--- table doesn't accidentally get saved later and clobber this change.
local function saveSettings(settings)
    _settings_cache = settings

    -- Serialize into an in-memory buffer first, so we can compare against the
    -- on-disk file and skip a redundant write (and its flush) when nothing
    -- changed — e-ink devices pay a real cost for needless disk writes.
    local buf = {}
    local function out(s)
        table.insert(buf, s)
    end
    out("return {\n")

    local function writeSet(name, tbl)
        out("    " .. name .. " = {\n")
        for k, v in pairs(tbl) do
            if v then
                out(string.format("        [%q] = true,\n", k))
            end
        end
        out("    },\n")
    end

    -- Like writeSet, but stores string values (id -> localized text) or
    -- the boolean `false` tombstone (id -> "confirmed absent") instead of
    -- boolean-true flags.
    local function writeTextCache(name, tbl)
        out("    " .. name .. " = {\n")
        for k, v in pairs(tbl) do
            if type(v) == "string" then
                out(string.format("        [%q] = %q,\n", k, v))
            elseif v == false then
                out(string.format("        [%q] = false,\n", k))
            end
        end
        out("    },\n")
    end

    --- Write custom_items_order_* as ordered arrays grouped by parent.
    local function writeOrderedItems(name, tbl)
        out("    " .. name .. " = {\n")
        if tbl then
            -- Sort parent keys for deterministic file output
            local parents = {}
            for parent in pairs(tbl) do
                table.insert(parents, parent)
            end
            table.sort(parents)
            for _, parent in ipairs(parents) do
                local ids = tbl[parent]
                if type(ids) == "table" and #ids > 0 then
                    out(string.format("        [%q] = {", parent))
                    for _, id in ipairs(ids) do
                        out(string.format("%q, ", id))
                    end
                    out("},\n")
                end
            end
        end
        out("    },\n")
    end

    writeSet("reader_disabled", settings.reader_disabled or {})
    writeSet("filemanager_disabled", settings.filemanager_disabled or {})
    writeSet("reader_tabs_disabled", settings.reader_tabs_disabled or {})
    writeSet("filemanager_tabs_disabled", settings.filemanager_tabs_disabled or {})
    writeTextCache("text_cache_reader", settings.text_cache_reader or {})
    writeTextCache("text_cache_filemanager", settings.text_cache_filemanager or {})
    writeTextCache("custom_items_reader", settings.custom_items_reader or {})
    writeTextCache("custom_items_filemanager", settings.custom_items_filemanager or {})
    writeOrderedItems("custom_items_order_reader", settings.custom_items_order_reader or {})
    writeOrderedItems("custom_items_order_filemanager", settings.custom_items_order_filemanager or {})
    writeOrderedItems("items_order_reader", settings.items_order_reader or {})
    writeOrderedItems("items_order_filemanager", settings.items_order_filemanager or {})
    writeTextCache("custom_tabs_reader", settings.custom_tabs_reader or {})
    writeTextCache("custom_tabs_filemanager", settings.custom_tabs_filemanager or {})
    writeTextCache("custom_tabs_after_reader", settings.custom_tabs_after_reader or {})
    writeTextCache("custom_tabs_after_filemanager", settings.custom_tabs_after_filemanager or {})
    out(string.format("    hide_unavailable = %s,\n", settings.hide_unavailable and "true" or "false"))
    out("}\n")

    local content = table.concat(buf)

    -- Skip the write entirely when the serialized content matches what we
    -- already know is on disk (in-memory cache). Fall back to a one-time file
    -- comparison when the cache is still cold for this session.
    if content == _last_saved_content and lfs.attributes(SETTINGS_FILE, "mode") then
        logger.info("MenuCustomizer: no changes, skip writing", SETTINGS_FILE)
        return
    end

    if lfs.attributes(SETTINGS_FILE, "mode") and not _last_saved_content then
        local f_in = io.open(SETTINGS_FILE, "r")
        if f_in then
            local old_content = f_in:read("*all")
            f_in:close()
            if old_content == content then
                _last_saved_content = content
                logger.info("MenuCustomizer: no changes, skip writing", SETTINGS_FILE)
                return
            end
        end
    end

    local f = io.open(SETTINGS_FILE, "w")
    if not f then
        logger.err("MenuCustomizer: cannot write", SETTINGS_FILE)
        return
    end
    f:write(content)
    f:flush()
    f:close()
    _last_saved_content = content
    logger.info("MenuCustomizer: flushed settings to", SETTINGS_FILE)
end

--- Move legacy inline caches (embedded in the main settings file before v1.9)
--- into the dedicated inline file, and rewrite the main file without them.
local function migrateInlineMenus()
    if lfs.attributes(INLINE_SETTINGS_FILE, "mode") then
        _legacy_inline_menus = nil
        return
    end
    local legacy = _legacy_inline_menus
    if not legacy then
        return
    end
    _legacy_inline_menus = nil
    if not (next(legacy.reader) or next(legacy.filemanager)) then
        return
    end
    _inline_cache = {
        reader = legacy.reader,
        filemanager = legacy.filemanager,
    }
    saveInlineMenus()
    -- Drop the embedded arrays from the main file as well.
    saveSettings(_settings_cache)
end

--- Get the shared, in-memory settings table, loading it from disk only the
--- first time it's needed in this session. All plugin code should call
--- this instead of loadSettingsFromDisk(), so every part of the plugin
--- reads and mutates the same table (see _settings_cache comment above).
local function getSettings()
    if not _settings_cache then
        _settings_cache = loadSettingsFromDisk()
        migrateInlineMenus()
    end
    return _settings_cache
end

--- Reset the inline-submenus cache and remove its file.
local function resetInlineMenus()
    _inline_cache = { reader = {}, filemanager = {} }
    _last_saved_inline_content = nil
    if lfs.attributes(INLINE_SETTINGS_FILE, "mode") then
        os.remove(INLINE_SETTINGS_FILE)
        logger.info("MenuCustomizer: removed", INLINE_SETTINGS_FILE)
    end
end

--- Deep-copy a "pristine order" snapshot (one level of array tables).
local function copyOrderSnapshot(src)
    local copy = {}
    for k, v in pairs(src) do
        if type(v) == "table" then
            copy[k] = shallowCopyArray(v)
        else
            copy[k] = v
        end
    end
    return copy
end

--- In-memory cache of the pristine (unmutated) order tables, keyed by mode.
--- Populated lazily, once per KOReader session, by getDefaultOrder() below.
local _pristine_order_cache = {}

--- Get the default (built-in) order table for a given mode.
--- MenuSorter:mergeAndSort mutates the cached require table in-place,
--- so after a restart with an override file the cached module already
--- has disabled items removed. The FIRST time this is called (which
--- happens before our mergeAndSort hook lets the original run, so the
--- module is still pristine), we temporarily evict the module from
--- package.loaded, re-require to get a fresh copy from disk
--- (frontend/ui/elements/), and deep-copy it into _pristine_order_cache.
--- Every subsequent call for that mode just returns a fresh deep-copy of
--- the cached snapshot instead of re-reading/re-parsing the file from
--- disk — this function used to run a full disk read on every menu
--- render and on every mergeAndSort call, which was the single most
--- expensive operation in the plugin.
local function getDefaultOrder(mode)
    if _pristine_order_cache[mode] then
        return copyOrderSnapshot(_pristine_order_cache[mode])
    end

    local module_path
    if mode == "reader" then
        module_path = "ui/elements/reader_menu_order"
    else
        module_path = "ui/elements/filemanager_menu_order"
    end

    -- Save the (possibly mutated) cached module
    local cached = package.loaded[module_path]
    -- Evict it so require re-reads the original file from disk
    package.loaded[module_path] = nil
    local ok, order_module = pcall(require, module_path)
    -- Restore the mutated version back into the cache
    package.loaded[module_path] = cached

    if not ok or not order_module then
        return {}
    end

    -- Deep-copy once into the session cache, then hand back a copy of that
    _pristine_order_cache[mode] = copyOrderSnapshot(order_module)
    return copyOrderSnapshot(_pristine_order_cache[mode])
end

--- Get the user-defined items-order override for a mode (reordering and
--- moving items between tabs/submenus). Stored per parent as an ordered
--- array of item ids, mirroring the format of custom_items_order_*.
local function getItemsOrder(settings, mode)
    return (mode == "reader") and settings.items_order_reader or settings.items_order_filemanager
end

--- Apply the user-defined items-order override onto an already-built order
--- table. Each entry is authoritative for its parent, so a moved item stays
--- where the user put it (it is listed in `mentioned` and thus not re-added
--- to its original parent), while items never touched by the user (not in
--- any override) keep their default position.
local function applyItemsOrder(order, items_order)
    if not items_order then return end

    -- Every id mentioned anywhere in the override is considered "handled":
    -- it must not be re-appended to a parent whose override omits it.
    local mentioned = {}
    for _, ordered_ids in pairs(items_order) do
        for _, id in ipairs(ordered_ids) do
            mentioned[id] = true
        end
    end

    -- Known ids currently present in the order (across all parents), used to
    -- drop stale override entries pointing at removed plugins/items.
    local known = {}
    for _, v in pairs(order) do
        if type(v) == "table" then
            for _, id in ipairs(v) do
                known[id] = true
            end
        end
    end

    for parent_id, ordered_ids in pairs(items_order) do
        if order[parent_id] then
            local result = {}
            local seen = {}
            for _, id in ipairs(ordered_ids) do
                if not seen[id] and (known[id] or id == SEPARATOR_ID) then
                    table.insert(result, id)
                    seen[id] = true
                end
            end
            for _, id in ipairs(order[parent_id]) do
                if not seen[id] and not mentioned[id] then
                    table.insert(result, id)
                    seen[id] = true
                end
            end
            order[parent_id] = result
        end
    end
end

--- Re-inject top-level tabs added at runtime by third-party plugins into the
--- pristine order (they are absent from the file on disk). Each tab is placed
--- right after the tab that preceded it when it was first discovered.
--- We materialize order[tab_id] (so the editor can show and toggle the tab's
--- items) ONLY when a non-empty child list was discovered for it. If nothing
--- was discovered, order[tab_id] is left nil: the generated override then
--- omits the tab's item-list key entirely, so MenuSorter keeps the plugin's
--- own runtime list verbatim instead of replacing it with an empty snapshot.
local function injectCustomTabs(order, settings, mode)
    local tabs = (mode == "reader") and settings.custom_tabs_reader or settings.custom_tabs_filemanager
    local afters = (mode == "reader") and settings.custom_tabs_after_reader or settings.custom_tabs_after_filemanager
    local custom_items_order = (mode == "reader") and settings.custom_items_order_reader or settings.custom_items_order_filemanager
    local buttons = order["KOMenu:menu_buttons"]
    if type(tabs) ~= "table" or type(buttons) ~= "table" then return end

    local present = {}
    for _, id in ipairs(buttons) do present[id] = true end

    local pending = {}
    for id in pairs(tabs) do
        local children = custom_items_order and custom_items_order[id]
        if type(children) == "table" and #children > 0 and type(order[id]) ~= "table" then
            order[id] = {}
        end
        if not present[id] then
            table.insert(pending, id)
        end
    end
    table.sort(pending)

    while #pending > 0 do
        local remaining = {}
        local progress = false
        for _, id in ipairs(pending) do
            local after = afters and afters[id] or ""
            local idx
            if after == "" then
                idx = 0
            else
                for i, b in ipairs(buttons) do
                    if b == after then
                        idx = i
                        break
                    end
                end
            end
            if idx then
                table.insert(buttons, idx + 1, id)
                progress = true
            else
                table.insert(remaining, id)
            end
        end
        if not progress then
            -- Predecessor is gone: just append the leftovers.
            for _, id in ipairs(remaining) do
                table.insert(buttons, id)
            end
            break
        end
        pending = remaining
    end
end

--- Get the effective order table for a given mode, merging the default
--- built-in order with any dynamically discovered custom menu items from
--- third-party plugins.
local function getEffectiveOrder(mode, settings)
    local order = getDefaultOrder(mode)
    injectCustomTabs(order, settings, mode)
    local custom_items_order = (mode == "reader") and settings.custom_items_order_reader or settings.custom_items_order_filemanager
    if custom_items_order then
        -- Insert custom items in the saved deterministic order
        for parent_id, ordered_ids in pairs(custom_items_order) do
            if order[parent_id] and type(order[parent_id]) == "table" then
                for _, item_id in ipairs(ordered_ids) do
                    local exists = false
                    for _, id in ipairs(order[parent_id]) do
                        if id == item_id then
                            exists = true
                            break
                        end
                    end
                    if not exists then
                        table.insert(order[parent_id], item_id)
                    end
                end
            end
        end
    end

    applyItemsOrder(order, getItemsOrder(settings, mode))

    return order
end

--- Serialize a Lua table of arrays into a string suitable for a menu_order file.
local function serializeOrder(order)
    local lines = {}
    table.insert(lines, "local Device = require(\"device\")\n")
    table.insert(lines, "local order = {")

    -- Write KOMenu:menu_buttons first
    local buttons = order["KOMenu:menu_buttons"]
    if buttons then
        table.insert(lines, "    [\"KOMenu:menu_buttons\"] = {")
        for _, v in ipairs(buttons) do
            table.insert(lines, string.format("        %q,", v))
        end
        table.insert(lines, "    },")
    end

    -- Write KOMenu:disabled if present
    local disabled = order["KOMenu:disabled"]
    if disabled and #disabled > 0 then
        table.insert(lines, "    [\"KOMenu:disabled\"] = {")
        for _, v in ipairs(disabled) do
            table.insert(lines, string.format("        %q,", v))
        end
        table.insert(lines, "    },")
    end

    -- Collect and sort remaining keys for deterministic output
    local keys = {}
    for k, _ in pairs(order) do
        if k ~= "KOMenu:menu_buttons" and k ~= "KOMenu:disabled" then
            table.insert(keys, k)
        end
    end
    table.sort(keys)

    for _, k in ipairs(keys) do
        local v = order[k]
        if type(v) == "table" then
            table.insert(lines, string.format("    [%q] = {", k))
            for _, item in ipairs(v) do
                table.insert(lines, string.format("        %q,", item))
            end
            table.insert(lines, "    },")
        end
    end

    table.insert(lines, "}")
    table.insert(lines, "")
    table.insert(lines, "if not Device:hasExitOptions() then")
    table.insert(lines, "    order.exit_menu = nil")
    table.insert(lines, "end")
    table.insert(lines, "")
    table.insert(lines, "return order")
    table.insert(lines, "")
    return table.concat(lines, "\n")
end

--- Generate the override file for a given mode.
local function generateOverrideFile(mode, settings)
    local order = getEffectiveOrder(mode, settings)
    local disabled_items = (mode == "reader") and settings.reader_disabled or settings.filemanager_disabled
    local disabled_tabs  = (mode == "reader") and settings.reader_tabs_disabled or settings.filemanager_tabs_disabled

    disabled_items = disabled_items or {}
    disabled_tabs  = disabled_tabs  or {}

    -- Collect all disabled item IDs for KOMenu:disabled (prevents orphan prefix)
    local all_disabled = {}

    -- 1. Remove disabled tabs from KOMenu:menu_buttons
    if order["KOMenu:menu_buttons"] then
        local new_buttons = {}
        for _, tab_id in ipairs(order["KOMenu:menu_buttons"]) do
            if disabled_tabs[tab_id] then
                table.insert(all_disabled, tab_id)
            else
                table.insert(new_buttons, tab_id)
            end
        end
        order["KOMenu:menu_buttons"] = new_buttons
    end

    -- 2. Remove disabled items from their respective submenus
    for submenu_id, submenu_items in pairs(order) do
        if type(submenu_items) == "table" and submenu_id ~= "KOMenu:menu_buttons" and submenu_id ~= "KOMenu:disabled" then
            local new_items = {}
            for _, item_id in ipairs(submenu_items) do
                if disabled_items[item_id] then
                    table.insert(all_disabled, item_id)
                else
                    table.insert(new_items, item_id)
                end
            end
            order[submenu_id] = new_items
        end
    end

    -- 3. Set KOMenu:disabled
    if #all_disabled > 0 then
        order["KOMenu:disabled"] = all_disabled
    end

    -- Write file only if content has changed
    local output_path = string.format("%s/%s_menu_order.lua",
        DataStorage:getSettingsDir(), mode)
    local content = serializeOrder(order)

    if lfs.attributes(output_path, "mode") then
        local f_in = io.open(output_path, "r")
        if f_in then
            local old_content = f_in:read("*all")
            f_in:close()
            if old_content == content then
                logger.info("MenuCustomizer: no changes, skip writing", output_path)
                return true
            end
        end
    end

    local f = io.open(output_path, "w")
    if not f then
        logger.err("MenuCustomizer: cannot write", output_path)
        return false
    end
    f:write(content)
    f:flush()
    f:close()
    logger.info("MenuCustomizer: flushed menu order to", output_path)
    return true
end

--- Remove override files.
local function removeOverrideFiles()
    for _, mode in ipairs({"reader", "filemanager"}) do
        local path = string.format("%s/%s_menu_order.lua",
            DataStorage:getSettingsDir(), mode)
        if lfs.attributes(path, "mode") then
            os.remove(path)
            logger.info("MenuCustomizer: removed", path)
        end
    end
end

-- ────────────────────────────────────────────────────────────────────
-- UI: Build hierarchical menu for viewing/toggling items
-- ────────────────────────────────────────────────────────────────────

--- Fallback labels for items that don't have .text in tab_item_table
--- (tabs are icon-based; submenus may lack explicit text entries).
--- Each entry is an { english, ukrainian } pair, resolved through tr().
local ENGLISH_SOURCES = {
    -- Tabs (icon-based, no .text in tab_item_table)
    navi                 = { "Navigation", "Навігація" },
    typeset              = { "Typeset", "Налаштування книжки" },
    setting              = { "Settings", "Налаштування" },
    tools                = { "Tools", "Інструменти" },
    search               = { "Search", "Пошук" },
    -- filemanager          = { "File browser", "Оглядач файлів" },
    main                 = { "More tools", "Додатково" },
    -- plus_menu            = { "Plus menu", "Додаткове меню" },
    filemanager_settings = { "File browser", "Файловий менеджер" },
    -- Submenus (may not have explicit text entries in tab_item_table)
    -- navi_settings        = { "Settings", "Налаштування" },
    -- document             = { "Document", "Документ" },
    -- device               = { "Device", "Пристрій" },
    -- navigation           = { "Navigation", "Навігація" },
    -- network              = { "Network", "Мережа" },
    -- screen               = { "Screen", "Екран" },
    -- taps_and_gestures    = { "Taps and gestures", "Жести й дотики" },
    -- more_tools           = { "More tools", "Додатково" },
    -- search_settings      = { "Settings", "Налаштування" },
    -- help                 = { "Help", "Довідка" },
    -- exit_menu            = { "Exit", "Вихід" },
}

--- Resolve a fallback label (an {en, uk} pair) for an id, or nil.
local function localizedSource(id)
    local source = ENGLISH_SOURCES[id]
    if type(source) == "table" then
        return tr(source[1], source[2])
    end
    return nil
end

--- Build a flat id→text lookup by traversing the already-sorted tab_item_table.
--- MenuSorter:sort() removes items from menu_items after placing them, so by the
--- time our UI runs, menu_items is empty.  However tab_item_table retains every
--- item with its .id and .text intact.
local function buildTextLookup(tab_item_table)
    local lookup = {}
    if not tab_item_table then return lookup end

    -- NOTE: We intentionally do NOT call sub_item_table_func here —
    -- those functions may open dialogs or perform heavy operations that
    -- block the main thread. We only traverse static sub_item_table data.
    local function traverse(items)
        if not items then return end
        for _, item in ipairs(items) do
            if type(item) == "table" then
                local text = nil
                if type(item.text) == "string" and item.text ~= "" then
                    text = item.text
                elseif type(item.text_func) == "function" then
                    local ok, res = pcall(item.text_func)
                    if ok and type(res) == "string" and res ~= "" then
                        text = res
                    end
                end

                if item.id and text then
                    lookup[item.id] = text
                end

                -- Recurse only into static sub_item_table (never sub_item_table_func)
                if type(item.sub_item_table) == "table" then
                    traverse(item.sub_item_table)
                end
            end
        end
    end

    for _, tab in ipairs(tab_item_table) do
        if type(tab) == "table" then
            traverse(tab)
        end
    end

    return lookup
end

--- Resolve the display label for a top-level TAB (KOMenu:menu_buttons
--- entry), as opposed to a regular submenu item.
--- Tabs are icon-only buttons: KOReader never puts .text/.text_func on
--- them in tab_item_table, in *either* mode, so live_lookup / the other
--- mode's cache can never confirm or deny them — trying to do so just
--- produces false "(unavailable in this mode)" noise for every tab.
--- Instead we hardcode their labels (English + Ukrainian) in ENGLISH_SOURCES
--- and resolve them through tr(), which follows the device language.
local function resolveTabLabel(tab_id, text_lookup)
    if text_lookup and text_lookup[tab_id] then
        return text_lookup[tab_id]
    end
    local source = localizedSource(tab_id)
    if source then
        return source
    end
    -- Tabs added by third-party plugins: label remembered at discovery time.
    local s = getSettings()
    for _, tbl in ipairs({ s.custom_tabs_reader, s.custom_tabs_filemanager }) do
        local label = type(tbl) == "table" and tbl[tab_id]
        if type(label) == "string" and label ~= "" then
            return label
        end
    end
    return tab_id
end

--- Resolve the display label for a menu item, distinguishing three states:
---   "ok"          - we have a real localized string for this item.
---   "unavailable" - confirmed absent: a previous session actually ran in
---                   this item's mode and the item was NOT registered
---                   (device incompatible, plugin disabled/missing, etc).
---   "unknown"     - never verified: neither the current live session nor
---                   the persistent cache for this mode has any record,
---                   so we can't tell "not yet checked" from "not there".
---
--- Priority:
--- 1. Live text_lookup from the *currently active* UI mode — always
---    authoritative when it has an answer.
--- 2. The other mode's persistent cache (see mergeTextCache): a string
---    means "ok", the boolean `false` tombstone means "unavailable".
--- 3. Static ENGLISH_SOURCES table (tab names, generic submenus).
--- 4. Fallback: raw item_id, status "unknown".
local function resolveItemLabel(item_id, text_lookup, other_mode_cache)
    if text_lookup and text_lookup[item_id] then
        return text_lookup[item_id], "ok"
    end
    if other_mode_cache then
        local cached = other_mode_cache[item_id]
        if type(cached) == "string" and cached ~= "" then
            return cached, "ok"
        elseif cached == false then
            return item_id, "unavailable"
        end
    end
    local source = localizedSource(item_id)
    if source then
        return source, "ok"
    end
    return item_id, "unknown"
end

--- Append a short status hint to a label for non-"ok" statuses, so the
--- user can tell "confirmed absent on this device/build" apart from
--- "not yet checked in that mode".
local function decorateLabel(label, status)
    if status == "unavailable" then
        return label .. " " .. tr("(unavailable in this mode)", "(недоступно в цьому режимі)")
    elseif status == "unknown" then
        return label .. " " .. tr("(needs verification)", "(потрібна перевірка)")
    end
    return label
end

--- Determine whether the given ui object belongs to the Reader or the
--- File manager. Returns "reader", "filemanager", or nil if undetermined.
local function detectMode(ui)
    if not ui then return nil end
    if ui.document then
        return "reader"
    elseif ui.file_chooser then
        return "filemanager"
    end
    return nil
end

--- Restart KOReader through the standard menu path: close the menu/UI, save
--- the current state, then re-exec via the restart exit code. Returns false
--- when the UI isn't ready for a programmatic restart (caller shows a
--- manual-restart message instead).
local function restartApp(ui)
    if not ui or not ui.menu or type(ui.menu.exitOrRestart) ~= "function" then
        return false
    end
    return pcall(function()
        ui.menu:exitOrRestart(function() UIManager:restartKOReader() end)
    end)
end

--- Localized label for a menu mode ("reader" / "filemanager").
local function modeLabel(mode)
    if mode == "reader" then
        return tr("Reader", "Читання")
    end
    return tr("File browser", "Оглядач файлів")
end

--- Collect every item id that the mode's menu_order structure *expects*
--- to exist inside submenus (NOT top-level tabs — tabs are icon-only
--- buttons that never carry .text/.text_func in tab_item_table, in any
--- mode, so they can never be confirmed "live" and must not be tombstoned
--- as unavailable; see resolveTabLabel, which hardcodes their names via
--- ENGLISH_SOURCES instead). This is our "checklist" for a given mode —
--- if an id from this list has no live text_func/text, that specific
--- item was genuinely not registered by any plugin in this session.
local function collectAllIds(order)
    local ids = {}
    for k, v in pairs(order) do
        if type(v) == "table" and k ~= "KOMenu:menu_buttons" and k ~= "KOMenu:disabled" then
            for _, id in ipairs(v) do
                if id ~= SEPARATOR_ID then
                    ids[id] = true
                end
            end
        end
    end
    return ids
end

--- Collect all known IDs (both menu array items and table keys) from an order table
local function collectKnownIds(order)
    local ids = {}
    for k, v in pairs(order) do
        ids[k] = true
        if type(v) == "table" and k ~= "KOMenu:menu_buttons" and k ~= "KOMenu:disabled" then
            for _, id in ipairs(v) do
                if id ~= SEPARATOR_ID then
                    ids[id] = true
                end
            end
        end
    end
    return ids
end

--- Merge the live (currently accurate) text_lookup for the active mode
--- into that mode's persistent text cache, and save if anything changed.
--- Call this every time the plugin's menu is opened, regardless of which
--- submenu ("Меню читання" / "Меню оглядача файлів") the user picks —
--- this way the cache for whichever mode you're actually in keeps itself
--- up to date, and the *other* mode's editor can read from it later.
---
--- For every id the menu_order structure expects in this mode: if it has
--- live text now, cache the string. If it does NOT have live text, and we
--- have never recorded anything for it before, tombstone it as `false`
--- ("confirmed absent this mode was actually checked") rather than just
--- leaving it unset ("never checked"). We never downgrade an existing
--- string back to a tombstone, since a stronger, positive result from an
--- earlier session shouldn't be erased by a transient miss.
local function mergeTextCache(settings, ui, mode_override)
    local mode = mode_override or detectMode(ui)
    if not mode or not ui.menu then return end
    local cache = (mode == "reader") and settings.text_cache_reader or settings.text_cache_filemanager
    if not cache then return end

    local changed = false

    -- Build text lookup and update cache for all expected IDs (including custom ones!)
    local live_lookup = buildTextLookup(ui.menu.tab_item_table)
    local expected_ids = collectAllIds(getEffectiveOrder(mode, settings))

    for id in pairs(expected_ids) do
        local live_text = live_lookup[id]
        if live_text then
            if cache[id] ~= live_text then
                cache[id] = live_text
                changed = true
            end
        elseif cache[id] == nil then
            cache[id] = false
            changed = true
        end
    end
    if changed then
        saveSettings(settings)
    end
end

--- Scan tab_item_table to discover submenus defined inline inside menu items
--- rather than as separate keys in the order table.
--- IMPORTANT: We only inspect static .sub_item_table — we NEVER call
--- .sub_item_table_func because those functions may show dialogs, do network
--- requests, or perform other blocking/UI operations. The static table is
--- present on items registered via addToMainMenu that already have their
--- sub_item_table built at registration time.
local function scanInlineSubmenus(tab_item_table, order)
    local inline_menus = {}
    if not tab_item_table then return inline_menus end

    local function extractChildren(items, parent_path)
        local list = {}
        for i, item in ipairs(items) do
            if type(item) == "table" and item.text ~= "KOMenu:separator" and item.id ~= SEPARATOR_ID then
                local text = item.text
                if (not text or text == "") and type(item.text_func) == "function" then
                    local ok, res = pcall(item.text_func)
                    if ok and type(res) == "string" then
                        text = res
                    end
                end

                local item_id = item.id
                -- Key suffix must be STABLE across sessions and values: use the
                -- static .text when present, otherwise fall back to the item's
                -- position in this list. Dynamic text_func output (e.g. a label
                -- like "Items per page: 3 x 2") must NOT go into the key, or a
                -- disabled item would reappear as soon as the shown value changes.
                local suffix = (type(item.text) == "string" and item.text ~= "") and item.text or ("#" .. i)
                local item_key = parent_path .. "::" .. (item_id or suffix)
                local display_text = (type(text) == "string" and text ~= "") and text or (item_id or ("#" .. i))

                -- Only static sub_item_table, never call sub_item_table_func
                local sub_table = type(item.sub_item_table) == "table" and item.sub_item_table or nil

                local entry = {
                    id = item_id,
                    key = item_key,
                    text = display_text,
                }

                if sub_table and #sub_table > 0 then
                    entry.is_submenu = true
                    entry.children = extractChildren(sub_table, item_key)
                else
                    entry.is_submenu = false
                end
                table.insert(list, entry)
            end
        end
        return list
    end

    local function checkItem(item)
        if type(item) ~= "table" then return end
        local item_id = item.id
        -- Only static sub_item_table, never call sub_item_table_func
        local sub_table = type(item.sub_item_table) == "table" and item.sub_item_table or nil

        if item_id and sub_table and #sub_table > 0 then
            if not order or not order[item_id] then
                -- This is an inline submenu not known to the order table
                inline_menus[item_id] = {
                    id = item_id,
                    key = item_id,
                    text = item.text,
                    children = extractChildren(sub_table, item_id),
                }
            else
                -- Known in order — still recurse into children for deeper inline submenus
                for _, sub in ipairs(sub_table) do
                    checkItem(sub)
                end
            end
        elseif sub_table then
            for _, sub in ipairs(sub_table) do
                checkItem(sub)
            end
        end
    end

    for _, tab in ipairs(tab_item_table) do
        if type(tab) == "table" then
            for _, item in ipairs(tab) do
                checkItem(item)
            end
        end
    end

    return inline_menus
end

--- Union-merge a freshly-scanned child list into an existing one, keyed by
--- `key`. Existing entries are kept even when absent from `fresh`, so disabled
--- (and thus already runtime-filtered out of the live menu) items stay
--- available in the plugin's own editor.
local function mergeChildrenInto(dst, src)
    local by_key = {}
    for _, e in ipairs(dst) do
        by_key[e.key] = e
    end
    for _, s in ipairs(src) do
        local existing = by_key[s.key]
        if existing then
            if s.children and existing.children then
                existing.children = mergeChildrenInto(existing.children, s.children)
            end
        else
            table.insert(dst, s)
            by_key[s.key] = s
        end
    end
    return dst
end

--- Union-merge a fresh inline-submenus scan into the persisted cache instead of
--- replacing it (which would drop previously disabled id-less children that the
--- live menu no longer contains after runtime filtering).
local function mergeInlineMenus(cache, fresh)
    for id, fresh_entry in pairs(fresh) do
        local existing = cache[id]
        if not existing then
            cache[id] = fresh_entry
        else
            existing.key = existing.key or fresh_entry.key
            if fresh_entry.text then existing.text = fresh_entry.text end
            if fresh_entry.children then
                existing.children = existing.children or {}
                mergeChildrenInto(existing.children, fresh_entry.children)
            end
        end
    end
end

--- Recursively filter out disabled items (both top-level and inline nested items)
--- from the live tab_item_table before TouchMenu displays it.
--- Removal happens in two passes so that the list positions (the fallback key
--- for id-less/static-text-less entries) are computed against the pristine list —
--- exactly the positions the scanner used — instead of shifting as items vanish.
local function filterItems(items, disabled, parent_path)
    if type(items) ~= "table" then return end

    local to_remove = {}
    for i = 1, #items do
        local item = items[i]
        if type(item) == "table" then
            local item_id = item.id
            -- Stable key: static .text if present, otherwise position in list.
            local suffix = (type(item.text) == "string" and item.text ~= "") and item.text or ("#" .. i)
            local item_key = parent_path and (parent_path .. "::" .. (item_id or suffix)) or item_id

            if (item_id and disabled[item_id]) or (item_key and disabled[item_key]) then
                to_remove[i] = true
            else
                -- Recurse into static submenus
                if type(item.sub_item_table) == "table" then
                    filterItems(item.sub_item_table, disabled, item_key)
                end
                -- Wrap sub_item_table_func, but only ONCE — guard with _mc_filtered flag
                -- to prevent infinite re-wrapping when mergeAndSort is called repeatedly.
                if type(item.sub_item_table_func) == "function" and not item._mc_filtered then
                    local orig_func = item.sub_item_table_func
                    local key_capture = item_key
                    item.sub_item_table_func = function(...)
                        local sub_items = orig_func(...)
                        if type(sub_items) == "table" then
                            filterItems(sub_items, disabled, key_capture)
                        end
                        return sub_items
                    end
                    item._mc_filtered = true  -- mark so we never wrap again
                end
            end
        end
    end

    -- Drop marked entries bottom-up so earlier indices stay meaningful.
    for i = #items, 1, -1 do
        if to_remove[i] then
            table.remove(items, i)
        end
    end

    -- Clean up consecutive or boundary separators. NOTE: only *standalone*
    -- separator rows qualify (id == SEPARATOR_ID or text == "KOMenu:separator").
    -- A real menu item merely flagged `separator = true` (draws the line above
    -- it, e.g. coverbrowser's "Mosaic and detailed list settings") must never be
    -- dropped here, even if a neighbouring item carries the same flag.
    local function isSeparatorEntry(e)
        return type(e) == "table"
            and (e.id == SEPARATOR_ID or e.text == "KOMenu:separator")
    end
    local j = 1
    while j <= #items do
        local is_sep = isSeparatorEntry(items[j])
        local prev_is_sep = (j > 1 and isSeparatorEntry(items[j - 1]))
        if is_sep and (j == 1 or prev_is_sep) then
            table.remove(items, j)
        else
            j = j + 1
        end
    end
    if #items > 0 and isSeparatorEntry(items[#items]) then
        table.remove(items, #items)
    end
end

--- Recursively collect all item IDs and keys under a given submenu (for bulk disable).
local function collectChildIds(submenu_id, order, inline_children)
    local ids = {}
    if inline_children then
        local function collectInline(children)
            for _, c in ipairs(children) do
                table.insert(ids, c.key)
                if c.id then table.insert(ids, c.id) end
                if c.children then collectInline(c.children) end
            end
        end
        collectInline(inline_children)
        return ids
    end

    local items = order and submenu_id and order[submenu_id]
    if not items or type(items) ~= "table" then return ids end
    for _, item_id in ipairs(items) do
        if item_id ~= SEPARATOR_ID then
            table.insert(ids, item_id)
            -- If this item is itself a submenu, recurse
            if order[item_id] then
                local child_ids = collectChildIds(item_id, order)
                for _, cid in ipairs(child_ids) do
                    table.insert(ids, cid)
                end
            end
        end
    end
    return ids
end

--- Tabs that should not appear in the plugin's editor UI.
local HIDDEN_TABS = {
    plus_menu = true,    -- FM: empty placeholder, not a real menu
    filemanager = true,  -- Reader: just a button to switch back to FM
}

--- Build a sub_item_table for a submenu's contents.
local function buildSubmenuItems(submenu_id, order, disabled_items, disabled_tabs, settings, mode, is_tab, text_lookup, other_mode_cache, hide_unavailable, inline_children)
    if hide_unavailable == nil then
        if settings and settings.hide_unavailable ~= nil then
            hide_unavailable = settings.hide_unavailable
        else
            hide_unavailable = true
        end
    end

    local sub_item_table = {}

    if inline_children then
        for _, child in ipairs(inline_children) do
            local child_key = child.key
            local child_text = child.text
            if child.is_submenu and child.children and #child.children > 0 then
                local sub_items = buildSubmenuItems(nil, order, disabled_items, disabled_tabs, settings, mode, false, text_lookup, other_mode_cache, hide_unavailable, child.children)
                table.insert(sub_item_table, {
                    text = child_text,
                    checked_func = function()
                        return not disabled_items[child_key]
                    end,
                    callback = function()
                        disabled_items[child_key] = not disabled_items[child_key] or nil
                        saveSettings(settings)
                    end,
                    hold_callback = function(touchmenu_instance)
                        local new_state = not disabled_items[child_key]
                        disabled_items[child_key] = new_state or nil
                        local child_ids = collectChildIds(nil, order, child.children)
                        for _, cid in ipairs(child_ids) do
                            disabled_items[cid] = new_state or nil
                        end
                        saveSettings(settings)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                    sub_item_table = sub_items,
                    keep_menu_open = true,
                })
            else
                table.insert(sub_item_table, {
                    text = child_text,
                    checked_func = function()
                        return not disabled_items[child_key]
                    end,
                    callback = function()
                        disabled_items[child_key] = not disabled_items[child_key] or nil
                        saveSettings(settings)
                    end,
                    keep_menu_open = true,
                })
            end
        end
        return sub_item_table
    end

    local items = order[submenu_id]
    if not items or type(items) ~= "table" then
        return {}
    end

    local inline_all = getInlineMenus()
    local inline_menus = (mode == "reader") and inline_all.reader or inline_all.filemanager
    inline_menus = inline_menus or {}

    for _, item_id in ipairs(items) do
        if item_id ~= SEPARATOR_ID then
            local is_order_submenu = (order[item_id] ~= nil) and (item_id ~= "KOMenu:menu_buttons") and (item_id ~= "KOMenu:disabled")
            local inline_info = inline_menus[item_id]

            if is_order_submenu then
                -- Recursively build submenu
                local localized, status = resolveItemLabel(item_id, text_lookup, other_mode_cache)
                if not (hide_unavailable and status == "unavailable") then
                    local sub_items = buildSubmenuItems(item_id, order, disabled_items, disabled_tabs, settings, mode, false, text_lookup, other_mode_cache, hide_unavailable)
                    if not (hide_unavailable and #sub_items == 0) then
                        local label = decorateLabel(localized, status)
                        table.insert(sub_item_table, {
                            text = label,
                            checked_func = function()
                                return not disabled_items[item_id]
                            end,
                            callback = function()
                                disabled_items[item_id] = not disabled_items[item_id] or nil
                                saveSettings(settings)
                            end,
                            hold_callback = function(touchmenu_instance)
                                local new_state = not disabled_items[item_id]
                                disabled_items[item_id] = new_state or nil
                                local child_ids = collectChildIds(item_id, order)
                                for _, cid in ipairs(child_ids) do
                                    disabled_items[cid] = new_state or nil
                                end
                                saveSettings(settings)
                                if touchmenu_instance then
                                    touchmenu_instance:updateItems()
                                end
                            end,
                            sub_item_table = sub_items,
                            keep_menu_open = true,
                        })
                    end
                end
            elseif inline_info and inline_info.children and #inline_info.children > 0 then
                -- Recursively build inline submenu
                local localized, status = resolveItemLabel(item_id, text_lookup, other_mode_cache)
                if (not localized or localized == item_id) and inline_info.text and inline_info.text ~= "" then
                    localized = inline_info.text
                    status = "ok"
                end
                if not (hide_unavailable and status == "unavailable") then
                    local sub_items = buildSubmenuItems(nil, order, disabled_items, disabled_tabs, settings, mode, false, text_lookup, other_mode_cache, hide_unavailable, inline_info.children)
                    local label = decorateLabel(localized, status)
                    table.insert(sub_item_table, {
                        text = label,
                        checked_func = function()
                            return not disabled_items[item_id]
                        end,
                        callback = function()
                            disabled_items[item_id] = not disabled_items[item_id] or nil
                            saveSettings(settings)
                        end,
                        hold_callback = function(touchmenu_instance)
                            local new_state = not disabled_items[item_id]
                            disabled_items[item_id] = new_state or nil
                            local child_ids = collectChildIds(nil, order, inline_info.children)
                            for _, cid in ipairs(child_ids) do
                                disabled_items[cid] = new_state or nil
                            end
                            saveSettings(settings)
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end,
                        sub_item_table = sub_items,
                        keep_menu_open = true,
                    })
                end
            else
                -- Regular item — toggle to disable/enable
                local localized, status = resolveItemLabel(item_id, text_lookup, other_mode_cache)
                if not (hide_unavailable and status == "unavailable") then
                    local display_text = decorateLabel(localized, status)
                    table.insert(sub_item_table, {
                        text = display_text,
                        checked_func = function()
                            return not disabled_items[item_id]
                        end,
                        callback = function()
                            disabled_items[item_id] = not disabled_items[item_id] or nil
                            saveSettings(settings)
                        end,
                        keep_menu_open = true,
                    })
                end
            end
        end
    end

    return sub_item_table
end

--- Build an ordered list of every reorderable container (top-level tabs and
--- nested submenus) for a given order table. Tabs keep their menu_buttons
--- order; submenus are appended sorted by id.
local function buildReorderableMenus(order)
    local list = {}
    local seen = {}

    for _, tab_id in ipairs(order["KOMenu:menu_buttons"] or {}) do
        if not HIDDEN_TABS[tab_id] and not seen[tab_id] then
            seen[tab_id] = true
            table.insert(list, { id = tab_id, is_tab = true })
        end
    end

    local submenus = {}
    for submenu_id, items in pairs(order) do
        if submenu_id ~= "KOMenu:menu_buttons"
                and submenu_id ~= "KOMenu:disabled"
                and type(items) == "table"
                and not seen[submenu_id] then
            table.insert(submenus, submenu_id)
        end
    end
    table.sort(submenus)
    for _, submenu_id in ipairs(submenus) do
        table.insert(list, { id = submenu_id, is_tab = false })
    end

    return list
end

--- Resolve a display label for a reorderable container (tab or submenu).
local function resolveContainerLabel(container_id, is_tab, text_lookup, other_mode_cache)
    if is_tab then
        return resolveTabLabel(container_id, text_lookup)
    end
    local localized, status = resolveItemLabel(container_id, text_lookup, other_mode_cache)
    return decorateLabel(localized, status)
end

--- Move an item between two menus/tabs, materializing both affected lists
--- into the items-order override so the change survives regeneration.
local function moveItemToMenu(mode, settings, item_id, from_menu_id, to_menu_id)
    local items_order = getItemsOrder(settings, mode)
    local order = getEffectiveOrder(mode, settings)

    local from_list = {}
    for _, id in ipairs(order[from_menu_id] or {}) do
        if id ~= item_id then
            table.insert(from_list, id)
        end
    end
    items_order[from_menu_id] = from_list

    local to_list = {}
    for _, id in ipairs(order[to_menu_id] or {}) do
        table.insert(to_list, id)
    end
    table.insert(to_list, item_id)
    items_order[to_menu_id] = to_list

    saveSettings(settings)
end

--- Show a chooser of all other tabs/submenus to move an item into.
local function showMoveDestinationChooser(mode, settings, item_id, from_menu_id, text_lookup, other_mode_cache, on_moved)
    local order = getEffectiveOrder(mode, settings)
    local containers = buildReorderableMenus(order)
    local item_label = resolveItemLabel(item_id, text_lookup, other_mode_cache)

    local choices = {}
    local chooser
    for __, entry in ipairs(containers) do
        local target_id = entry.id
        if target_id ~= from_menu_id and order[target_id] then
            local label = resolveContainerLabel(target_id, entry.is_tab, text_lookup, other_mode_cache)
            local prefix = entry.is_tab and tr("[Tab] ", "[Вкладка] ") or tr("[Menu] ", "[Меню] ")
            table.insert(choices, {
                text = prefix .. label,
                callback = function()
                    UIManager:close(chooser)
                    moveItemToMenu(mode, settings, item_id, from_menu_id, target_id)
                    if on_moved then on_moved() end
                end,
            })
        end
    end

    if #choices == 0 then
        UIManager:show(InfoMessage:new{
            text = tr("There are no other tabs or submenus to move to.", "Немає інших вкладок чи підменю для переміщення."),
        })
        return
    end

    chooser = Menu:new{
        title = T(tr("Move \"%1\" to:", "Перемістити «%1» в:"), item_label),
        item_table = choices,
        is_popout = false, -- square corners (no rounded popup look)
		is_borderless = true, 
    }
    UIManager:show(chooser)
end

--- Open a SortWidget to reorder the items of a single menu/tab.
local function showReorderSortWidget(mode, settings, menu_id, text_lookup, other_mode_cache)
    local order = getEffectiveOrder(mode, settings)
    local items = order[menu_id]
    if not items or type(items) ~= "table" then
        UIManager:show(InfoMessage:new{
            text = tr("This menu has no items to reorder.", "Це меню не містить пунктів для зміни порядку."),
        })
        return
    end

    local is_tab = false
    for _, tab_id in ipairs(order["KOMenu:menu_buttons"] or {}) do
        if tab_id == menu_id then
            is_tab = true
            break
        end
    end

    local sort_widget
    local rebuild

    local function build_sort_items()
        local current_order = getEffectiveOrder(mode, settings)
        local current_items = current_order[menu_id] or {}
        local list = {}
        for __, item_id in ipairs(current_items) do
            if item_id == SEPARATOR_ID then
                table.insert(list, {
                    text = tr("--- Separator ---", "--- Розділювач ---"),
                    item_id = SEPARATOR_ID,
                })
            else
                local localized, status = resolveItemLabel(item_id, text_lookup, other_mode_cache)
                table.insert(list, {
                    text = decorateLabel(localized, status),
                    item_id = item_id,
                    hold_callback = function()
                        showMoveDestinationChooser(mode, settings, item_id, menu_id, text_lookup, other_mode_cache, rebuild)
                    end,
                })
            end
        end
        return list
    end

    rebuild = function()
        if not sort_widget then return end
        sort_widget.item_table = build_sort_items()
        sort_widget.marked = 0
        sort_widget.orig_item_table = nil
        sort_widget.show_page = 1
        sort_widget.pages = math.max(1, math.ceil(#sort_widget.item_table / sort_widget.items_per_page))
        sort_widget:_populateItems()
    end

    local sort_items = build_sort_items()
    if #sort_items == 0 then
        UIManager:show(InfoMessage:new{
            text = tr("This menu has no items to reorder.", "Це меню не містить пунктів для зміни порядку."),
        })
        return
    end

    local menu_label = resolveContainerLabel(menu_id, is_tab, text_lookup, other_mode_cache)

    sort_widget = SortWidget:new{
        title = T(tr("Reorder: %1", "Змінити порядок: %1"), menu_label),
        item_table = sort_items,
        callback = function()
            local new_list = {}
            for _, sort_item in ipairs(sort_widget.item_table) do
                table.insert(new_list, sort_item.item_id)
            end
            local items_order = getItemsOrder(settings, mode)
            items_order[menu_id] = new_list
            saveSettings(settings)
        end,
    }

    function sort_widget:onShowWidgetMenu()
        local this = self
        local marked_item = (this.marked > 0 and this.item_table[this.marked]) or nil
        if not marked_item or not marked_item.item_id or marked_item.item_id == SEPARATOR_ID then
            UIManager:show(InfoMessage:new{
                text = tr("First mark an item (tap its row) to move it to another tab or menu.", "Спершу позначте пункт (тап по рядку), щоб перемістити його в іншу вкладку чи меню."),
            })
            return true
        end
        local dialog
        dialog = ButtonDialog:new{
            shrink_unneeded_width = true,
            buttons = {
                {{
                    text = tr("Move to another tab/menu…", "Перемістити в іншу вкладку/меню…"),
                    align = "left",
                    callback = function()
                        UIManager:close(dialog)
                        showMoveDestinationChooser(mode, settings, marked_item.item_id, menu_id, text_lookup, other_mode_cache, rebuild)
                    end,
                }},
            },
            anchor = function()
                return this.title_bar.left_button.image.dimen
            end,
        }
        UIManager:show(dialog)
        return true
    end

    UIManager:show(sort_widget)
end

--- Show a chooser of menus/tabs to pick the one whose items to reorder.
local function showReorderChooser(mode, settings, text_lookup, other_mode_cache)
    local order = getEffectiveOrder(mode, settings)
    local containers = buildReorderableMenus(order)

    if #containers == 0 then
        UIManager:show(InfoMessage:new{
            text = tr("No tabs or submenus available.", "Немає доступних вкладок чи підменю."),
        })
        return
    end

    local choices = {}
    local chooser
    for __, entry in ipairs(containers) do
        local container_id = entry.id
        local label = resolveContainerLabel(container_id, entry.is_tab, text_lookup, other_mode_cache)
        local prefix = entry.is_tab and tr("[Tab] ", "[Вкладка] ") or tr("[Menu] ", "[Меню] ")
        table.insert(choices, {
            text = prefix .. label,
            callback = function()
                UIManager:close(chooser)
                showReorderSortWidget(mode, settings, container_id, text_lookup, other_mode_cache)
            end,
        })
    end

    chooser = Menu:new{
        title = tr("Select a tab or menu to reorder", "Виберіть вкладку чи меню для зміни порядку"),
        item_table = choices,
        is_popout = false, -- square corners (no rounded popup look)
		is_borderless = true, 
    }
    UIManager:show(chooser)
end

--- Build the top-level menu structure for a mode (reader or filemanager).
local function buildModeMenu(mode, settings, text_lookup, other_mode_cache, ui)
    local order = getEffectiveOrder(mode, settings)
    local disabled_items = (mode == "reader") and settings.reader_disabled or settings.filemanager_disabled
    local disabled_tabs  = (mode == "reader") and settings.reader_tabs_disabled or settings.filemanager_tabs_disabled

    local tabs = order["KOMenu:menu_buttons"]
    if not tabs then return {} end

    local sub_item_table = {}

    for _, tab_id in ipairs(tabs) do
        -- Skip tabs that shouldn't appear in the editor
        if not HIDDEN_TABS[tab_id] then
        -- Tabs get their hardcoded English-source label (see resolveTabLabel) —
        -- they're icon-only buttons, never "unavailable" or "unknown".
        local label = resolveTabLabel(tab_id, text_lookup)
        local tab_items = buildSubmenuItems(tab_id, order, disabled_items, disabled_tabs, settings, mode, true, text_lookup, other_mode_cache, settings.hide_unavailable)

        -- Insert toggle for the entire tab + its sub-items
        table.insert(sub_item_table, {
            text = label,
            checked_func = function()
                return not disabled_tabs[tab_id]
            end,
            callback = function()
                disabled_tabs[tab_id] = not disabled_tabs[tab_id] or nil
                saveSettings(settings)
            end,
            hold_callback = function(touchmenu_instance)
                -- Long-tap: disable this tab AND all its children
                local new_state = not disabled_tabs[tab_id]
                disabled_tabs[tab_id] = new_state or nil
                local child_ids = collectChildIds(tab_id, order)
                for _, cid in ipairs(child_ids) do
                    disabled_items[cid] = new_state or nil
                end
                saveSettings(settings)
                if touchmenu_instance then
                    touchmenu_instance:updateItems()
                end
            end,
            sub_item_table = tab_items,
            keep_menu_open = true,
        })
        end -- if not HIDDEN_TABS
    end

    -- Separator + action buttons
    if #sub_item_table > 0 then
        sub_item_table[#sub_item_table].separator = true
    end
    table.insert(sub_item_table, {
        text = tr("Reorder / move items", "Змінити порядок / перемістити пункти"),
        keep_menu_open = true,
        callback = function()
            showReorderChooser(mode, settings, text_lookup, other_mode_cache)
        end,
    })
    table.insert(sub_item_table, {
        text = tr("Apply changes (restart required)", "Застосувати зміни (потрібен перезапуск)"),
        keep_menu_open = true,
        callback = function()
            if generateOverrideFile(mode, settings) then
                if not restartApp(ui) then
                    local mode_label = modeLabel(mode)
                    UIManager:show(InfoMessage:new{
                        text = T(tr("Menu order file for '%1' mode created.\n\nRestart KOReader to apply the changes.", "Файл порядку меню для режиму '%1' успішно створено.\n\nПерезапустіть KOReader, щоб застосувати зміни."), mode_label),
                    })
                end
            else
                UIManager:show(InfoMessage:new{
                    text = tr("Failed to create the menu order file.", "Помилка створення файлу порядку меню."),
                })
            end
        end,
    })
    table.insert(sub_item_table, {
        text = tr("Reset to defaults", "Скинути за замовчуванням"),
        keep_menu_open = true,
        callback = function()
            if mode == "reader" then
                settings.reader_disabled = {}
                settings.reader_tabs_disabled = {}
                settings.items_order_reader = {}
            else
                settings.filemanager_disabled = {}
                settings.filemanager_tabs_disabled = {}
                settings.items_order_filemanager = {}
            end
            saveSettings(settings)

            -- Remove override file for this mode
            local path = string.format("%s/%s_menu_order.lua",
                DataStorage:getSettingsDir(), mode)
            if lfs.attributes(path, "mode") then
                os.remove(path)
                logger.info("MenuCustomizer: removed", path)
            end

            if not restartApp(ui) then
                local mode_label = modeLabel(mode)
                UIManager:show(InfoMessage:new{
                    text = T(tr("Menu for '%1' mode reset to defaults.\n\nRestart KOReader to apply.", "Меню режиму '%1' скинуто за замовчуванням.\n\nПерезапустіть KOReader для застосування."), mode_label),
                })
            end
        end,
    })

    return sub_item_table
end

-- ────────────────────────────────────────────────────────────────────
-- Plugin lifecycle
-- ────────────────────────────────────────────────────────────────────

--- Discover top-level tabs that a third-party plugin added to the live
--- KOMenu:menu_buttons (they are not part of the pristine order on disk).
--- Persists id -> label and id -> predecessor tab so getEffectiveOrder() can
--- re-inject them. Returns (changed, tab_set) where tab_set holds every known
--- custom tab id (live or remembered), so callers never mistake a tab
--- definition in item_table for an ordinary menu item and never copy the
--- tab's contents into custom_items_order_* (that would make the override
--- file rewrite the plugin's own item list).
local function discoverCustomTabs(config_prefix, item_table, order, settings, default_order)
    local tab_set = {}
    local buttons = order["KOMenu:menu_buttons"]
    local tabs_key = "custom_tabs_" .. config_prefix
    local after_key = "custom_tabs_after_" .. config_prefix
    settings[tabs_key] = settings[tabs_key] or {}
    settings[after_key] = settings[after_key] or {}
    local tabs, afters = settings[tabs_key], settings[after_key]
    local disabled_tabs = (config_prefix == "reader") and settings.reader_tabs_disabled or settings.filemanager_tabs_disabled

    for id in pairs(tabs) do tab_set[id] = true end
    if type(buttons) ~= "table" then return false, tab_set end

    local default_tabs = {}
    for _, id in ipairs(default_order["KOMenu:menu_buttons"] or {}) do
        default_tabs[id] = true
    end

    local changed = false
    local live = {}
    local prev = ""
    for _, id in ipairs(buttons) do
        if type(id) == "string" and id ~= SEPARATOR_ID and not default_tabs[id] and not TAB_IDS[id] then
            live[id] = true
            tab_set[id] = true
            local label = tabs[id]
            local def = type(item_table) == "table" and item_table[id] or nil
            if type(def) == "table" and type(def.text) == "string" and def.text ~= "" then
                label = def.text
            elseif not label then
                label = id
            end
            if tabs[id] ~= label then
                tabs[id] = label
                changed = true
            end
            -- Remember the position only once, on first discovery: later
            -- live lists may already have disabled tabs stripped out.
            if afters[id] == nil then
                afters[id] = prev
                changed = true
            end
        end
        prev = id
    end

    -- Forget tabs that vanished (plugin removed/disabled). A tab the user
    -- disabled is missing from the live list by design, so keep it.
    for id in pairs(tabs) do
        if not live[id] and not (disabled_tabs and disabled_tabs[id]) then
            tabs[id] = nil
            afters[id] = nil
            tab_set[id] = nil
            local items_order = (config_prefix == "reader") and settings.items_order_reader or settings.items_order_filemanager
            if items_order then items_order[id] = nil end
            changed = true
        end
    end

    return changed, tab_set
end

--- Discover third-party plugin items before MenuSorter applies override files.
--- This catches:
---   1. Items explicitly inserted by plugins into submenus of 'order' during addToMainMenu
---   2. Items in 'item_table' that define a sorting_hint
---   3. Items without either, defaulting to the first tab (navi/path)
local function discoverCustomItemsBeforeSort(config_prefix, item_table, order, settings)
    if not order or type(order) ~= "table" then return false end
    if config_prefix ~= "reader" and config_prefix ~= "filemanager" then return false end

    local default_order = getDefaultOrder(config_prefix)
    local known_ids = collectKnownIds(default_order)
    local tabs_changed, tab_set = discoverCustomTabs(config_prefix, item_table, order, settings, default_order)
    for id in pairs(tab_set) do
        known_ids[id] = true -- a custom tab is a container, never a plain item
    end
    local custom_items = (config_prefix == "reader") and settings.custom_items_reader or settings.custom_items_filemanager
    if not custom_items then
        custom_items = {}
        if config_prefix == "reader" then
            settings.custom_items_reader = custom_items
        else
            settings.custom_items_filemanager = custom_items
        end
    end

    -- discovered: id -> parent_id (hash for quick lookup)
    -- discovered_order: parent_id -> {id1, id2, ...} (preserves order)
    local discovered = {}
    local discovered_order = {}

    local function addDiscovered(id, parent)
        discovered[id] = parent
        if not discovered_order[parent] then
            discovered_order[parent] = {}
        end
        table.insert(discovered_order[parent], id)
    end

    -- 1. Discover items explicitly inserted into submenus of 'order' by plugins.
    --    ipairs preserves the insertion order from addToMainMenu.
    for submenu_id, submenu_list in pairs(order) do
        if type(submenu_list) == "table" and submenu_id ~= "KOMenu:menu_buttons" and submenu_id ~= "KOMenu:disabled" then
            for _, id in ipairs(submenu_list) do
                if id ~= SEPARATOR_ID and not known_ids[id] then
                    addDiscovered(id, submenu_id)
                end
            end
        end
    end

    -- 2. Discover items in 'item_table' that specify a sorting_hint.
    --    pairs() is non-deterministic, so collect and sort for stability.
    if item_table and type(item_table) == "table" then
        local hint_items = {}
        for item_id, item_data in pairs(item_table) do
            if item_id ~= SEPARATOR_ID and not known_ids[item_id] and not discovered[item_id] then
                if type(item_data) == "table" and item_data.sorting_hint and type(item_data.sorting_hint) == "string" then
                    local hint = item_data.sorting_hint
                    if order[hint] and type(order[hint]) == "table" then
                        table.insert(hint_items, { id = item_id, parent = hint })
                    end
                end
            end
        end
        table.sort(hint_items, function(a, b) return a.id < b.id end)
        for _, entry in ipairs(hint_items) do
            addDiscovered(entry.id, entry.parent)
        end
    end

    -- 3. Only if a plugin item has neither an order insertion nor a sorting_hint,
    --    default to the first tab (navi/path). Sorted for stability.
    if item_table and type(item_table) == "table" then
        local orphans = {}
        for item_id, item_data in pairs(item_table) do
            if item_id ~= SEPARATOR_ID and not known_ids[item_id] and not discovered[item_id] then
                if type(item_data) == "table" and item_id ~= "KOMenu:separator" and item_id ~= "KOMenu:disabled" and item_id ~= "KOMenu:menu_buttons" then
                    table.insert(orphans, item_id)
                end
            end
        end
        table.sort(orphans)
        local first_tab = (order["KOMenu:menu_buttons"] and order["KOMenu:menu_buttons"][1]) or "navi"
        for _, item_id in ipairs(orphans) do
            addDiscovered(item_id, first_tab)
        end
    end

    -- Update custom_items hash
    local changed = tabs_changed
    for id, parent in pairs(discovered) do
        if custom_items[id] ~= parent then
            custom_items[id] = parent
            changed = true
        end
    end

    -- Prune custom items that are no longer present
    for id in pairs(custom_items) do
        if not discovered[id] then
            local parent = custom_items[id]
            custom_items[id] = nil
            local disabled_tbl = (config_prefix == "reader") and settings.reader_disabled or settings.filemanager_disabled
            local cache_tbl = (config_prefix == "reader") and settings.text_cache_reader or settings.text_cache_filemanager
            -- Keep the disable flag for items that belong to a custom tab: a
            -- disabled child is removed from the live tab list by our own
            -- override, so on a later re-scan it can look "vanished" and would
            -- be silently re-enabled. Keeping the flag makes the disable stick.
            if disabled_tbl and disabled_tbl[id] ~= nil and not (parent and tab_set[parent]) then
                disabled_tbl[id] = nil
            end
            if cache_tbl and cache_tbl[id] ~= nil then
                cache_tbl[id] = nil
            end
            changed = true
        end
    end

    -- Rebuild the ordered arrays from discovered_order, preserving the
    -- saved order for items that haven't moved. New items are appended
    -- at the end of their parent's list.
    local order_key = (config_prefix == "reader") and "custom_items_order_reader" or "custom_items_order_filemanager"
    local old_ordered = settings[order_key] or {}
    local new_ordered = {}

    -- Collect all parent IDs from both old and discovered
    local all_parents = {}
    for parent in pairs(old_ordered) do all_parents[parent] = true end
    for parent in pairs(discovered_order) do all_parents[parent] = true end

    for parent in pairs(all_parents) do
        local old_list = old_ordered[parent] or {}
        local new_discovered = discovered_order[parent] or {}
        local new_set = {}
        for _, id in ipairs(new_discovered) do new_set[id] = true end

        -- Start with old order, keeping only items that still exist
        local result = {}
        local seen = {}
        for _, id in ipairs(old_list) do
            if new_set[id] then
                table.insert(result, id)
                seen[id] = true
            end
        end
        -- Append newly discovered items not in the old list
        for _, id in ipairs(new_discovered) do
            if not seen[id] then
                table.insert(result, id)
            end
        end

        if #result > 0 then
            new_ordered[parent] = result
        end
    end

    -- Detect if ordered arrays changed
    local function arraysEqual(a, b)
        if #a ~= #b then return false end
        for i = 1, #a do
            if a[i] ~= b[i] then return false end
        end
        return true
    end
    for parent in pairs(all_parents) do
        local old = old_ordered[parent] or {}
        local new = new_ordered[parent] or {}
        if not arraysEqual(old, new) then
            changed = true
            break
        end
    end

    settings[order_key] = new_ordered

    return changed
end

function MenuCustomizer:hookMenuSorter()
    local ok, MenuSorter = pcall(require, "ui/menusorter")
    if not ok or not MenuSorter or MenuSorter._menucustomizer_hooked then
        return
    end
    local orig_mergeAndSort = MenuSorter.mergeAndSort
    MenuSorter._menucustomizer_hooked = true

    MenuSorter.mergeAndSort = function(ms_self, config_prefix, item_table, order)
        if config_prefix == "reader" or config_prefix == "filemanager" then
            local settings = getSettings()
            local changed = discoverCustomItemsBeforeSort(config_prefix, item_table, order, settings)
            local settings_dir = DataStorage:getSettingsDir()
            local override_path = string.format("%s/%s_menu_order.lua", settings_dir, config_prefix)

            if changed then
                saveSettings(settings)
            end

            if changed or lfs.attributes(override_path) then
                generateOverrideFile(config_prefix, settings)
            end
        end

        local tab_item_table = orig_mergeAndSort(ms_self, config_prefix, item_table, order)

        if config_prefix == "reader" or config_prefix == "filemanager" then
            local settings = getSettings()

            -- NOTE: The inline-submenu scan no longer runs here. It used to run
            -- once per session on the first menu build, adding a full traversal
            -- plus a large settings write to the first top-menu open. The scan
            -- now happens only when the plugin's own editor is opened (see the
            -- sub_item_table_func in addToMainMenu below).
            local disabled_items = (config_prefix == "reader") and settings.reader_disabled or settings.filemanager_disabled
            if disabled_items and next(disabled_items) then
                -- tab_item_table is an array of tabs; each tab is an array of
                -- menu items. Filter each tab separately so inline (id-less)
                -- submenu items like "sort_by::some_label" are actually reached.
                for _, tab_items in ipairs(tab_item_table) do
                    filterItems(tab_items, disabled_items)
                end
            end
        end

        return tab_item_table
    end
end

function MenuCustomizer:init()
    self.ui.menu:registerToMainMenu(self)
    self:hookMenuSorter()
end

function MenuCustomizer:addToMainMenu(menu_items)
    local ok_ro, order = pcall(require, "ui/elements/reader_menu_order")
    if ok_ro and order and order.more_tools then
        local found = false
        for _, id in ipairs(order.more_tools) do
            if id == "menu_customizer" then found = true; break end
        end
        if not found then table.insert(order.more_tools, "menu_customizer") end
    end
    local ok_fo, fm_order = pcall(require, "ui/elements/filemanager_menu_order")
    if ok_fo and fm_order and fm_order.more_tools then
        local found = false
        for _, id in ipairs(fm_order.more_tools) do
            if id == "menu_customizer" then found = true; break end
        end
        if not found then table.insert(fm_order.more_tools, "menu_customizer") end
    end

    menu_items.menu_customizer = {
        text = tr("Menu customizer", "Налаштування меню"),
        -- sorting_hint замінено на явне додавання в reader_menu_order та filemanager_menu_order
        sub_item_table = {
            {
                text = tr("Reader menu", "Меню читання"),
                sub_item_table_func = function()
                    local settings = getSettings()
                    -- Keep whichever mode we're actually running in up to
                    -- date, so the *other* mode's cache below stays fresh
                    -- across sessions.
                    mergeTextCache(settings, self.ui)
                    if self.ui and self.ui.menu and self.ui.menu.tab_item_table and detectMode(self.ui) == "reader" then
                        -- Merge (not overwrite): the live menu may already be
                        -- runtime-filtered, so a plain overwrite would drop
                        -- disabled id-less children and make them un-reenableable.
                        local scanned = scanInlineSubmenus(self.ui.menu.tab_item_table, getDefaultOrder("reader"))
                        if scanned and next(scanned) then
                            local inline = getInlineMenus()
                            inline.reader = inline.reader or {}
                            mergeInlineMenus(inline.reader, scanned)
                            saveInlineMenus()
                        end
                    end
                    local text_lookup = buildTextLookup(self.ui.menu.tab_item_table)
                    return buildModeMenu("reader", settings, text_lookup, settings.text_cache_reader, self.ui)
                end,
            },
            {
                text = tr("File browser menu", "Меню оглядача файлів"),
                separator = true,
                sub_item_table_func = function()
                    local settings = getSettings()
                    mergeTextCache(settings, self.ui)
                    if self.ui and self.ui.menu and self.ui.menu.tab_item_table and detectMode(self.ui) == "filemanager" then
                        -- Merge (not overwrite): see the reader branch above.
                        local scanned = scanInlineSubmenus(self.ui.menu.tab_item_table, getDefaultOrder("filemanager"))
                        if scanned and next(scanned) then
                            local inline = getInlineMenus()
                            inline.filemanager = inline.filemanager or {}
                            mergeInlineMenus(inline.filemanager, scanned)
                            saveInlineMenus()
                        end
                    end
                    local text_lookup = buildTextLookup(self.ui.menu.tab_item_table)
                    return buildModeMenu("filemanager", settings, text_lookup, settings.text_cache_filemanager, self.ui)
                end,
            },
            {
                text = tr("Refresh translations cache", "Оновити кеш перекладів"),
                keep_menu_open = true,
                callback = function()
                    local settings = getSettings()
                    local mode = detectMode(self.ui)
                    if not mode then
                        UIManager:show(InfoMessage:new{
                            text = tr("Could not determine the current mode (reader or file browser).", "Не вдалося визначити поточний режим (читання чи оглядач файлів)."),
                        })
                        return
                    end

                    mergeTextCache(settings, self.ui, mode)

                    local cache = (mode == "reader") and settings.text_cache_reader or settings.text_cache_filemanager
                    local ok_count, unavailable_count = 0, 0
                    for _, v in pairs(cache) do
                        if type(v) == "string" then
                            ok_count = ok_count + 1
                        elseif v == false then
                            unavailable_count = unavailable_count + 1
                        end
                    end

                    local mode_label = modeLabel(mode)
                    local other_mode_label = modeLabel(mode == "reader" and "filemanager" or "reader")
                    UIManager:show(InfoMessage:new{
                        text = T(tr("Translations cache for '%1' mode refreshed.\n\nWith translation: %2\nUnavailable in this mode: %3\n\nTo refresh the cache for '%4' mode, open this menu while in that mode.", "Кеш перекладів для режиму '%1' оновлено.\n\nЗ перекладом: %2\nНедоступні в цьому режимі: %3\n\nЩоб оновити кеш для режиму '%4', відкрийте це меню, перебуваючи в тому режимі."),
                            mode_label, ok_count, unavailable_count, other_mode_label),
                    })
                end,
            },
            {
                text = tr("Hide unavailable items", "Приховувати недоступні пункти"),
                checked_func = function()
                    local settings = getSettings()
                    return settings.hide_unavailable
                end,
                callback = function()
                    local settings = getSettings()
                    settings.hide_unavailable = not settings.hide_unavailable
                    saveSettings(settings)
                end,
                separator = true,
                keep_menu_open = true,
            },
            {
                text = tr("Apply all changes", "Застосувати всі зміни"),
                keep_menu_open = true,
                callback = function()
                    local settings = getSettings()
                    local ok1 = generateOverrideFile("reader", settings)
                    local ok2 = generateOverrideFile("filemanager", settings)
                    if ok1 and ok2 then
                        if not restartApp(self.ui) then
                            UIManager:show(InfoMessage:new{
                                text = tr("Menu order files for reader and file browser created.\n\nRestart KOReader to apply the changes.", "Файли порядку меню для читання та оглядача файлів створено.\n\nПерезапустіть KOReader, щоб застосувати зміни."),
                            })
                        end
                    else
                        UIManager:show(InfoMessage:new{
                            text = tr("Failed to create some menu order files.", "Помилка створення деяких файлів порядку меню."),
                        })
                    end
                end,
            },
            {
                text = tr("Reset everything to defaults", "Скинути все за замовчуванням"),
                keep_menu_open = true,
                callback = function()
                    -- Clear all settings
                    local settings = {
                        reader_disabled = {},
                        filemanager_disabled = {},
                        reader_tabs_disabled = {},
                        filemanager_tabs_disabled = {},
                        text_cache_reader = {},
                        text_cache_filemanager = {},
                        custom_items_reader = {},
                        custom_items_filemanager = {},
                        custom_items_order_reader = {},
                        custom_items_order_filemanager = {},
                        items_order_reader = {},
                        items_order_filemanager = {},
                        custom_tabs_reader = {},
                        custom_tabs_filemanager = {},
                        custom_tabs_after_reader = {},
                        custom_tabs_after_filemanager = {},
                        hide_unavailable = true,
                    }
                    saveSettings(settings)
                    removeOverrideFiles()
                    resetInlineMenus()
                    if not restartApp(self.ui) then
                        UIManager:show(InfoMessage:new{
                            text = tr("All menu settings were reset to defaults.\n\nRestart KOReader to apply.", "Усі налаштування меню скинуто за замовчуванням.\n\nПерезапустіть KOReader для застосування."),
                        })
                    end
                end,
            },
            {
                text = tr("Created files info", "Інформація про створені файли"),
                keep_menu_open = true,
                callback = function()
                    local settings_dir = DataStorage:getSettingsDir()
                    local reader_path = settings_dir .. "/reader_menu_order.lua"
                    local fm_path = settings_dir .. "/filemanager_menu_order.lua"
                    local reader_exists = lfs.attributes(reader_path, "mode") ~= nil
                    local fm_exists = lfs.attributes(fm_path, "mode") ~= nil

                    local created_label = tr("created", "створено")
                    local not_created_label = tr("not created", "не створено")
                    local text = tr("Created settings files:\n\n", "Створені файли налаштувань:\n\n")
                    text = text .. tr("Reader: ", "Читання: ") .. (reader_exists and (created_label .. " (" .. reader_path .. ")") or not_created_label) .. "\n\n"
                    text = text .. tr("File browser: ", "Оглядач файлів: ") .. (fm_exists and (created_label .. " (" .. fm_path .. ")") or not_created_label)

                    UIManager:show(InfoMessage:new{
                        text = text,
                    })
                end,
            },
        },
    }
end

return MenuCustomizer
