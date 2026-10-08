-- v1.1: renamed the English plugin name from "Menu settings" to "Menu customizer".
-- v1.0: localized plugin metadata (en/uk via tr/trn).

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

return {
    fullname = tr("Menu customizer", "Налаштування меню"),
    description = tr(
        "Shows the full menu hierarchy for reader and file browser modes. Allows disabling individual tabs, submenus and menu items. Generates custom menu order files in the settings directory.",
        "Відображає повну ієрархію меню для режимів читання та оглядача файлів. Дозволяє вимикати окремі вкладки, підменю та пункти меню. Створює файли кастомного порядку меню в теці налаштувань."),
}
