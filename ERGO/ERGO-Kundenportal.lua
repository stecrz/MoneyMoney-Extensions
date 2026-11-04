-- ERGO-Kundenportal.lua
--
-- MoneyMoney Web Banking Extension fuer das ERGO Kundenportal
-- "Meine Versicherungen" (kunde-s.ergo.de). Deckt ERGO- und DKV-Vertraege ab.
--
-- Liest alle Vertraege des Kontos aus und legt fuer jeden Vertrag mit Wert
-- ein Konto/Depot in MoneyMoney an. Nichts ist fest verdrahtet: weder
-- Vertragsnummern noch ISINs noch Produktnamen -- alles wird generisch aus
-- der ERGO-JSON-API gelesen. Anmeldedaten sind Benutzername und Passwort
-- des ERGO Kundenportals; der SMS-Code (Zwei-Faktor) wird bei jeder
-- Anmeldung in einem MoneyMoney-Dialog abgefragt.
--
-- FUNKTIONSWEISE
--   1. GET kunde-s.ergo.de -> Redirect-Kette zum ForgeRock-Login (ciam.ergo.com)
--   2. POST /am/json/.../authenticate (leer)      -> authId + Callbacks
--   3. Callback-Baum generisch abarbeiten:
--        NameCallback/PasswordCallback  -> Benutzername/Passwort
--        ConfirmationCallback           -> Hinweisseite ("Verstanden") bestaetigen,
--                                          Text als ERGO-Hinweis merken
--        TextInputCallback "SMS-Kennwort" -> MoneyMoney-Dialog, Code vom Nutzer
--        TextOutputCallback             -> Hinweise sammeln (JS ignorieren)
--      ... bis tokenId (SSO-Cookie) vorliegt
--   4. OAuth2-form_post-Formulare automatisch absenden bis zum Dashboard
--   5. Geaenderte Nutzungsbedingungen (Portalbedingungen.aspx) erkennen:
--      je nach TERMS_MODE in MoneyMoney zur Zustimmung vorlegen, automatisch
--      zustimmen oder mit Hinweis abbrechen
--   6. __RequestVerificationToken aus dem HTML ziehen
--   7. GET apps.kunde-s.ergo.de/prod/api/v1/contracts  -> Vertragsliste
--   8. POST /meineversicherungen/L1/api/spa {"contractDetails":[{...}]}
--      -> Guthaben und Fondspositionen aus dem dataFields-Baum
--
-- HINWEIS ZUR ZWEI-FAKTOR-AUTHENTIFIZIERUNG
--   ERGO verlangt seit 2026 bei JEDER Anmeldung einen SMS-Code. Eine
--   automatische Hintergrund-Aktualisierung ohne Nutzer ist damit technisch
--   nicht moeglich; das Konto wird beim manuellen Aktualisieren abgefragt.
--
-- INSTALLATION
--   Signierte Version: einfach in den Extensions-Ordner legen.
--   Unsigniert (Eigenbau): MoneyMoney > Einstellungen > Extensions >
--     "Digitale Signatur von Extensions ueberpruefen" deaktivieren.
--   Ordner oeffnen: MoneyMoney > Hilfe > Datenbank im Finder zeigen.
--   Danach: Konto hinzufuegen > Andere > ERGO Kundenportal
--
-- Fehlersuche: DEBUG unten auf true setzen, dann Fenster > Protokollfenster.
-- Lizenz: CC0 1.0 (Public-Domain-Freigabe). Soweit rechtlich moeglich, wird
-- auf alle Urheber- und verwandten Rechte an dieser Software verzichtet. Sie
-- wird OHNE JEDE GEWAEHR bereitgestellt. Lizenztext:
-- https://creativecommons.org/publicdomain/zero/1.0/
-- Keine Verbindung zur ERGO Group AG oder zu MRH applications (MoneyMoney).

WebBanking{
  version     = 1.08,
  url         = "https://kunde-s.ergo.de/",
  services    = {"ERGO Kundenportal"},
  description = "Vertragsguthaben und Fondsdepots aus dem ERGO Kundenportal (ERGO/DKV). " ..
                "Anmeldung mit Benutzername, Passwort und SMS-Code (Zwei-Faktor)."
}

-- ---------------------------------------------------------------------------
-- Konfiguration
-- ---------------------------------------------------------------------------

-- true : fondsgebundene UND klassische Vertraege werden als Depot angelegt.
--        MoneyMoney speichert bei Depots den Bestand jedes Rundrufs lokal und
--        baut daraus den Wertverlauf -- Historie ab sofort, wie bei Trade
--        Republic. Klassische Vertraege ohne Fonds bekommen eine einzelne
--        synthetische Position (Vertragsguthaben/Rueckkaufswert).
-- false: ein Konto je Vertrag mit dem Guthaben als Saldo. Achtung: Den
--        Saldenverlauf normaler Konten rekonstruiert MoneyMoney aus Umsaetzen;
--        ohne Umsaetze gibt es KEINE Historie, nur den aktuellen Wert.
local PORTFOLIO_MODE = true

-- true : auch Vertraege ohne bezifferbaren Wert (z.B. reine Risikopolicen wie
--        Kfz/Haftpflicht) als 0-Euro-Konto anzeigen. Standard: nur Vertraege
--        mit Guthaben, damit die Kontenliste nicht mit Nullwerten zulaeuft.
local INCLUDE_ALL_CONTRACTS = false

-- Umgang mit geaenderten Nutzungsbedingungen. ERGO legt sie NUR dann vor,
-- wenn sie sich geaendert haben und noch nicht bestaetigt wurden (einmalig je
-- Aenderung, nicht bei jedem Login); ohne Zustimmung ist das Portal gesperrt.
--   "ask"   : Text der Aenderung im MoneyMoney-Dialog anzeigen. Eingabe "ja"
--             = Zustimmung direkt aus MoneyMoney. Jede andere Eingabe (auch
--             leer) = nicht zustimmen; der Abruf wird trotzdem versucht und
--             erst bei Misserfolg erscheint der Hinweis, im Browser
--             zuzustimmen. (Standard)
--   "auto"  : automatisch zustimmen; der Text landet nur im Protokoll.
--   "never" : nie fragen, nie zustimmen; Abruf trotzdem versuchen, bei
--             Misserfolg Hinweis mit dem Text der Aenderung.
local TERMS_MODE = "ask"

-- true : Hinweise, die ERGO waehrend der Anmeldung einblendet (z.B. die
--        Information zur Zwei-Faktor-Einfuehrung), im SMS-Dialog mit
--        anzeigen. Sie erscheinen in jedem Fall im Protokollfenster.
local SHOW_NOTICES = true

-- true : ausfuehrliche Protokollausgaben (Rohantworten, Feldlaengen der
--        Zugangsdaten, Quellen-Trefferzahlen). Fuer den Normalbetrieb aus,
--        fuer die Fehlersuche an. Fehlermeldungen erscheinen immer.
local DEBUG = false

local BASE      = "https://kunde-s.ergo.de"
local CIAM      = "https://ciam.ergo.com"
local APPS_URL  = "https://apps.kunde-s.ergo.de/prod/api/v1/contracts"
local AUTH_URL  = CIAM .. "/am/json/realms/root/realms/customerportal/authenticate"
local API_URL   = BASE .. "/meineversicherungen/L1/api/spa"
local DASHBOARD = BASE .. "/meineversicherungen/L1/Startseite/Dashboard.aspx"
local LOGOUT    = CIAM .. "/am/UI/Logout?realm=/customerportal"

-- Notnagel: Falls die automatische Vertragserkennung leer bleibt, hier die
-- Werte aus der URL der Detailseite eintragen (?vnr=...&verwSysSl=...).
-- Leer lassen, solange die Erkennung funktioniert.
local MANUAL_CONTRACTS = {
  -- {vnr = "060012345", verwSysSl = "LF"},
}

-- Reihenfolge bestimmt, welches Feld als Kontosaldo gilt (Kleinschreibung,
-- Teilstring-Vergleich gegen den Feldtitel). Deckt fondsgebundene, klassische
-- und Renten-/Sofortrentenprodukte ab.
local BALANCE_KEYS = {
  "aktuellen vertragsguthabens",
  "vertragsguthaben",
  "rückkaufswert", "rueckkaufswert",
  "aktuellen fondsanlage",
  "fondsanlage",
  "fondsguthaben",
  "deckungskapital",
  "deckungsrückstellung", "deckungsrueckstellung",
  "rentenkapital",
  "guthaben aus überschüssen", "guthaben aus ueberschuessen",
  "vertragswert",
  "kapitalwert",
  "auszahlungsbetrag",
  "guthaben"
}

-- Positive Antwortoptionen einer ForgeRock-Bestaetigungsseite (Kleinschreibung)
local POSITIVE_OPTIONS = {
  "verstanden", "ok", "weiter", "ja", "yes", "akzeptieren", "zustimmen",
  "bestätigen", "bestaetigen", "submit", "continue", "accept", "fortfahren"
}

local function dbg (...) if DEBUG then print(...) end end

-- ---------------------------------------------------------------------------
-- Zustand
-- ---------------------------------------------------------------------------

local connection      = nil
local rvToken         = nil
local contracts       = nil   -- { {vnr=, verwSysSl=}, ... }
local contractMeta    = {}    -- normVnr -> {product, owner, company, status, currency, bankBalance}
local detailsCache    = {}    -- vnr -> geparste Detaildaten
local lastRawResponse = nil
local pending         = nil   -- offener Dialogschritt: {kind="otp", auth=} | {kind="terms", page=}
local notices         = {}    -- waehrend der Anmeldung gesammelte ERGO-Hinweise

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

local function conn ()
  if connection == nil then
    connection = Connection()
    connection.language  = "de-DE"
    connection.useragent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " ..
                           "AppleWebKit/537.36 (KHTML, like Gecko) " ..
                           "Chrome/126.0.0.0 Safari/537.36"
  end
  return connection
end

local function headerValue (headers, name)
  if type(headers) ~= "table" then return nil end
  name = name:lower()
  for k, v in pairs(headers) do
    if type(k) == "string" and k:lower() == name then return v end
  end
  return nil
end

-- Relative Location-Angabe gegen die Ausgangs-URL aufloesen; http->https
local function resolveLocation (base, loc)
  if loc:match("^https?://") then
    return (loc:gsub("^http://", "https://"))
  end
  local origin = base:match("^(https?://[^/]+)") or BASE
  if loc:sub(1, 1) == "/" then return origin .. loc end
  return origin .. "/" .. loc
end

-- Request mit defensiver Redirect-Verfolgung. MoneyMoney folgt Redirects in
-- der Regel selbst; falls nicht, uebernimmt das diese Schleife.
local function request (method, url, body, contentType, headers)
  local content, charset, mimeType, filename, respHeaders =
    conn():request(method, url, body, contentType, headers)

  local hops, current = 0, url
  while hops < 10 do
    local loc = headerValue(respHeaders, "location")
    if loc == nil or loc == "" then break end
    hops = hops + 1
    current = resolveLocation(current, loc)
    content, charset, mimeType, filename, respHeaders =
      conn():request("GET", current, nil, nil, headers)
  end

  return content, charset, mimeType, respHeaders
end

local JSON_HEADERS = {
  ["Accept"]             = "application/json",
  ["Accept-API-Version"] = "protocol=1.0,resource=2.1",
  ["X-Requested-With"]   = "forgerock-sdk"
}

local function postJSON (url, tbl, headers)
  local body = "{}"
  if tbl ~= nil then body = JSON():set(tbl):json() end
  local content = request("POST", url, body, "application/json", headers)
  lastRawResponse = content
  if content == nil or content == "" then return nil end
  local ok, data = pcall(function () return JSON(content):dictionary() end)
  if not ok then
    dbg("Antwort ist kein JSON: " .. tostring(url))
    return nil
  end
  return data
end

-- ---------------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------------

-- Vertragsnummer fuer Vergleiche normalisieren. MoneyMoney entfernt beim
-- Speichern der Kontonummer fuehrende Nullen ("060012345" -> "60012345"),
-- daher muss der Abgleich Null-tolerant sein.
local function normalizeVnr (s)
  s = tostring(s or ""):gsub("%s", ""):gsub("^0+", "")
  if s == "" then s = "0" end
  return s
end

-- Anzeigetext saeubern: weiche Trennstriche (U+00AD) entfernen, Whitespace
-- normalisieren. ERGO liefert z.B. "Renten\194\173ver\194\173si\194\173che\194\173rung".
local function cleanText (s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("\194\173", "")
  s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  return s
end

-- HTML-Entities aufloesen (benannte + numerische)
local function decodeEntities (s)
  if type(s) ~= "string" then return s end
  s = s:gsub("&nbsp;", " "):gsub("&quot;", '"'):gsub("&#39;", "'")
       :gsub("&lt;", "<"):gsub("&gt;", ">")
  if utf8 and utf8.char then
    s = s:gsub("&#(%d+);", function (n)
      local ok, c = pcall(utf8.char, tonumber(n))
      return ok and c or ""
    end)
  end
  s = s:gsub("&amp;", "&")
  return s
end

-- HTML -> lesbarer Klartext fuer MoneyMoney-Dialoge und das Protokoll
local function stripHtml (s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("<script.-</script>", ""):gsub("<style.-</style>", "")
  s = s:gsub("[\r\n\t]+", " ")   -- Zeilenumbrueche im HTML-Quelltext sind unbedeutend
  s = s:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n"):gsub("</h%d>", "\n")
       :gsub("</li>", "\n"):gsub("<li[^>]*>", "- "):gsub("</ul>", "\n")
       :gsub("</ol>", "\n"):gsub("</div>", "\n")
  s = s:gsub("<[^>]+>", "")
  s = decodeEntities(s)
  s = s:gsub("\194\173", "")
  s = s:gsub("[ \t\r]+", " "):gsub(" *\n *", "\n"):gsub("\n\n\n+", "\n\n")
       :gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then return nil end
  return s
end

-- "7.981,80 EUR" -> 7981.80 ; alles andere -> nil
local function parseMoney (s)
  if type(s) ~= "string" then return nil end
  local sign, int, dec = s:match("^%s*(%-?)([%d%.]+),(%d%d)%s*EUR%s*$")
  if int == nil then return nil end
  local n = tonumber((int:gsub("%.", "")) .. "." .. dec)
  if n == nil then return nil end
  if sign == "-" then n = -n end
  return n
end

-- Rekursiv durch den dataFields-Baum laufen
local function walkFields (fields, fn)
  if type(fields) ~= "table" then return end
  for _, f in ipairs(fields) do
    if type(f) == "table" then
      fn(f)
      walkFields(f["fields"], fn)
    end
  end
end

-- Saldo nach Prioritaetsliste bestimmen. Gibt (Betrag, Feldtitel) zurueck.
local function findBalance (dataFields)
  local hits = {}
  walkFields(dataFields, function (f)
    local amount = parseMoney(f["value"])
    if amount ~= nil and type(f["title"]) == "string" then
      table.insert(hits, {title = f["title"], lower = f["title"]:lower(), amount = amount})
    end
  end)

  for _, key in ipairs(BALANCE_KEYS) do
    for _, h in ipairs(hits) do
      if h.lower:find(key, 1, true) then return h.amount, cleanText(h.title) end
    end
  end
  return nil, nil
end

-- Fondspositionen: Abschnitt mit Geldbetrag, der eine ISIN als Unterfeld hat
local function findFunds (fields, out)
  if type(fields) ~= "table" then return end
  for _, f in ipairs(fields) do
    if type(f) == "table" then
      local amount = parseMoney(f["value"])
      local isin = nil
      if amount ~= nil then
        walkFields(f["fields"], function (g)
          if type(g["title"]) == "string" and g["title"]:upper() == "ISIN"
             and type(g["value"]) == "string" and g["value"] ~= "" then
            isin = g["value"]
          end
        end)
      end
      if amount ~= nil and isin ~= nil then
        table.insert(out, {name = f["title"] or isin, isin = isin, amount = amount})
      else
        findFunds(f["fields"], out)
      end
    end
  end
end

-- Wert eines Feldes mit exaktem Titel
local function fieldValue (dataFields, title)
  local result = nil
  walkFields(dataFields, function (f)
    if result == nil and type(f["title"]) == "string"
       and f["title"]:lower() == title:lower()
       and type(f["value"]) == "string" and f["value"] ~= "" then
      result = f["value"]
    end
  end)
  return result
end

-- Vertrag aufnehmen (mit Dedup)
local function collectContract (out, seen, vnr, sys)
  if type(vnr) ~= "string" or vnr == "" then return end
  if type(sys) ~= "string" or sys == "" then return end
  local key = sys .. "/" .. vnr
  if not seen[key] then
    seen[key] = true
    table.insert(out, {vnr = vnr, verwSysSl = sys})
  end
end

-- Vertraege rekursiv einsammeln. Zwei Muster:
--   1. explizite Geschwisterfelder vnr + verwSysSl (z.B. inbox/dashboardList)
--   2. beliebiger String mit "...?vnr=060012345&verwSysSl=LF..." (detailsUrl
--      im apps/contracts-Endpunkt und in der contractList-Antwort)
-- Muster 2 liefert die korrekte fuehrende Null; das Feld "id" (z.B.
-- "LF60012345") wird bewusst NICHT verwendet, da dort die Null fehlt.
local function findContracts (node, out, seen)
  if type(node) ~= "table" then return end

  collectContract(out, seen, node["vnr"], node["verwSysSl"])

  for _, v in pairs(node) do
    if type(v) == "string" then
      local vnr = v:match("[?&]vnr=([^&]+)")
      local sys = v:match("[?&]verwSysSl=([^&]+)")
      if vnr and sys then
        collectContract(out, seen, MM.urldecode(vnr), MM.urldecode(sys))
      end
    elseif type(v) == "table" then
      findContracts(v, out, seen)
    end
  end
end

-- ---------------------------------------------------------------------------
-- ERGO-Hinweise (Meldungen waehrend der Anmeldung)
-- ---------------------------------------------------------------------------

local function addNotice (text)
  text = stripHtml(text)
  if text == nil or text == "" or text == "." then return end
  for _, n in ipairs(notices) do
    if n == text then return end
  end
  table.insert(notices, text)
  print("ERGO-Hinweis: " .. text:gsub("\n+", " | "))
end

local function noticesText ()
  if not SHOW_NOTICES or #notices == 0 then return "" end
  return "Hinweis von ERGO:\n" .. table.concat(notices, "\n\n") .. "\n\n"
end

-- ---------------------------------------------------------------------------
-- Anmeldung: ForgeRock-Callback-Baum
-- ---------------------------------------------------------------------------

local function cbOutput (cb, name)
  for _, o in ipairs(cb["output"] or {}) do
    if o["name"] == name then return o["value"] end
  end
  return nil
end

local function setInputs (cb, value)
  for _, inp in ipairs(cb["input"] or {}) do inp["value"] = value end
end

local function positiveOption (options)
  if type(options) ~= "table" then return 0 end
  for idx, opt in ipairs(options) do
    local o = tostring(opt):lower()
    for _, p in ipairs(POSITIVE_OPTIONS) do
      if o == p then return idx - 1 end
    end
  end
  return 0
end

local function looksLikeOtp (prompt)
  local p = (prompt or ""):lower()
  return p:find("sms") or p:find("otp") or p:find("one time") or p:find("one-time")
      or p:find("einmal") or p:find("code") or p:find("tan") or p:find("kennwort")
      or p:find("sicherheits")
end

-- Callbacks eines Knotens befuellen.
-- creds = {username=, password=, code=}; creds.code wird beim Verbrauch auf
-- nil gesetzt. Liefert (needsInput, label): needsInput=true, wenn ein Wert
-- vom Nutzer fehlt (dann ist label die Feldbezeichnung).
local function fillCallbacks (auth, creds)
  local needsInput, label = false, nil
  local texts = {}
  local codeUsed = false

  for _, cb in ipairs(auth["callbacks"] or {}) do
    local t = cb["type"]
    local prompt = cbOutput(cb, "prompt")

    if t == "TextOutputCallback" then
      local mt = tostring(cbOutput(cb, "messageType") or "0")
      if mt ~= "4" then table.insert(texts, cbOutput(cb, "message")) end   -- 4 = JavaScript

    elseif t == "NameCallback" then
      local p = (prompt or ""):lower()
      if creds.username ~= nil
         and (p:find("user") or p:find("benutzer") or p:find("login") or p == "name") then
        setInputs(cb, creds.username)
      elseif creds.code ~= nil then
        setInputs(cb, creds.code); creds.code = nil; codeUsed = true
      else
        needsInput, label = true, (prompt or "Code")
      end

    elseif t == "PasswordCallback" then
      local p = (prompt or ""):lower()
      if creds.password ~= nil and not looksLikeOtp(p) then
        setInputs(cb, creds.password)
      elseif creds.code ~= nil then
        setInputs(cb, creds.code); creds.code = nil; codeUsed = true
      else
        needsInput, label = true, (prompt or "Code")
      end

    elseif t == "TextInputCallback" then
      if creds.code ~= nil then
        setInputs(cb, creds.code); creds.code = nil; codeUsed = true
      else
        needsInput, label = true, (prompt or "SMS-Kennwort")
      end

    elseif t == "ConfirmationCallback" then
      setInputs(cb, positiveOption(cbOutput(cb, "options")))
      addNotice(auth["header"])
      addNotice(auth["description"])

    elseif t == "ChoiceCallback" then
      setInputs(cb, cbOutput(cb, "defaultChoice") or 0)

    elseif t == "HiddenValueCallback" or t == "MetadataCallback"
        or t == "SuspendedTextOutputCallback" or t == "PollingWaitCallback" then
      -- unveraendert zuruecksenden

    else
      if cb["input"] ~= nil and #cb["input"] > 0 then
        error("Nicht unterstuetzter Anmeldeschritt von ERGO: " .. tostring(t))
      end
    end
  end

  -- Texte eines Knotens, der als Dialog angezeigt wurde oder wird, nicht
  -- zusaetzlich als Hinweis merken (sonst erschienen sie doppelt).
  if not needsInput and not codeUsed then
    for _, m in ipairs(texts) do addNotice(m) end
  end

  return needsInput, label
end

-- Protokolliert, OB Zugangsdatenfelder befuellt wurden (Laenge, nicht Wert)
local function logFilled (auth)
  if not DEBUG then return end
  for _, cb in ipairs(auth["callbacks"] or {}) do
    for _, inp in ipairs(cb["input"] or {}) do
      local v = inp["value"]
      dbg(string.format("  %s.%s = %s", tostring(cb["type"]), tostring(inp["name"]),
        (type(v) == "string") and (#v .. " Zeichen") or tostring(v)))
    end
  end
end

-- Dialogtext fuer den aktuellen Knoten (Ueberschrift, Beschreibung, Hinweise)
local function promptText (auth)
  local parts = {}
  local h = stripHtml(auth["header"]); if h then table.insert(parts, h) end
  local d = stripHtml(auth["description"]); if d then table.insert(parts, d) end
  for _, cb in ipairs(auth["callbacks"] or {}) do
    if cb["type"] == "TextOutputCallback"
       and tostring(cbOutput(cb, "messageType") or "0") ~= "4" then
      local m = stripHtml(cbOutput(cb, "message"))
      if m and m ~= "." then table.insert(parts, m) end
    end
  end
  return table.concat(parts, "\n")
end

-- Den Callback-Baum abarbeiten, bis ein tokenId vorliegt oder Nutzereingabe
-- noetig ist. Liefert:
--   "ok",     auth                         (tokenId vorhanden)
--   "prompt", {text=, label=, auth=}       (Nutzereingabe noetig)
--   "failed", meldung
local function runAuthTree (auth, creds)
  for step = 1, 12 do
    if auth == nil then return "failed", "Keine Antwort vom Anmeldeserver." end

    if auth["tokenId"] ~= nil then return "ok", auth end

    if auth["callbacks"] == nil then
      local code = auth["code"]
      local msg  = auth["message"]
      if code == 401 or code == "401" then
        return "failed", "401:" .. tostring(msg)
      end
      return "failed", "Anmeldefehler: " .. tostring(msg or auth["reason"] or "unbekannt")
    end

    -- Wartenknoten (z.B. Push-Freigabe): kurz warten, dann erneut senden
    for _, cb in ipairs(auth["callbacks"]) do
      if cb["type"] == "PollingWaitCallback" then
        local ms = tonumber(cbOutput(cb, "waitTime")) or 3000
        MM.sleep(ms / 1000)
      end
    end

    local text = promptText(auth)
    local needsInput, label = fillCallbacks(auth, creds)
    if needsInput then
      return "prompt", {text = text, label = label, auth = auth}
    end

    -- Felder des Knotens vor dem Senden aufraeumen (Browser sendet sie nicht)
    auth["status"] = nil; auth["ok"] = nil

    logFilled(auth)
    dbg("Anmeldeschritt " .. step .. " senden")
    auth = postJSON(AUTH_URL, auth, JSON_HEADERS)
  end
  return "failed", "Anmeldung hat zu viele Schritte."
end

-- ---------------------------------------------------------------------------
-- Anmeldung: Portal oeffnen, Nutzungsbedingungen, Verifikations-Token
-- ---------------------------------------------------------------------------

local function extractRvToken (content)
  if type(content) ~= "string" then return nil end
  local token = content:match('name="__RequestVerificationToken"[^>]-value="([^"]*)"')
                or content:match('value="([^"]*)"[^>]-name="__RequestVerificationToken"')
  if token ~= nil and token ~= "" then return token end
  return nil
end

local function isTermsPage (content)
  return type(content) == "string"
     and content:find("__doPostBack", 1, true) ~= nil
     and (content:find("Portalbedingungen", 1, true) ~= nil
          or content:find("Nutzungsbedingungen", 1, true) ~= nil)
     and content:match(">%s*Zustimmen%s*<") ~= nil
end

-- Text der Nutzungsbedingungs-Seite fuer Dialog und Protokoll
local function termsText (content)
  local parts = {}
  local h = stripHtml(content:match('<h1[^>]*id="headline"[^>]*>(.-)</h1>')
                      or content:match("<h1[^>]*>(.-)</h1>"))
  if h then table.insert(parts, h) end
  local body = content:match('<div class="markeInfo">(.-)</div>')
  if body == nil then
    body = content:match('class="[^"]*page"[^>]*>(.-)<div class="button%-navigation')
  end
  local b = stripHtml(body)
  if b then table.insert(parts, b) end
  local pdf = content:match('href="(https?://[^"]*Nutzungsbedingungen[^"]*%.pdf)"')
  if pdf then table.insert(parts, "Dokument: " .. pdf) end
  if #parts == 0 then
    table.insert(parts, "ERGO verlangt die Zustimmung zu geaenderten Nutzungsbedingungen.")
  end
  return table.concat(parts, "\n\n")
end

-- Nutzungsbedingungen per ASP.NET-Postback bestaetigen (Button "Zustimmen").
-- Alle versteckten Formularfelder werden uebernommen, __EVENTTARGET auf das
-- Postback-Ziel des Zustimmen-Links gesetzt.
local function acceptTerms (content)
  local target = content:match("__doPostBack%(&#39;([^&]-)&#39;,&#39;&#39;%)\"[^>]*>%s*Zustimmen")
              or content:match("__doPostBack%('([^']-)',''%)\"[^>]*>%s*Zustimmen")
  if target == nil then
    return nil, "Zustimmen-Schaltflaeche nicht gefunden."
  end

  local action = content:match('<form[^>]*id="aspnetForm"[^>]*action="([^"]*)"')
              or content:match('<form[^>]*action="([^"]*)"[^>]*id="aspnetForm"')
              or "/meineversicherungen/L1/Formulare/Allgemein/Portalbedingungen.aspx?m=1"
  action = decodeEntities(action)
  local url = resolveLocation(BASE, action)

  local fields, seen = {}, {}
  for tag in content:gmatch("<input[^>]*>") do
    if tag:find('type="hidden"', 1, true) then
      local name  = tag:match('name="([^"]*)"')
      local value = tag:match('value="([^"]*)"') or ""
      if name and not seen[name] then
        seen[name] = true
        table.insert(fields, {name = name, value = decodeEntities(value)})
      end
    end
  end
  if not seen["__EVENTTARGET"] then table.insert(fields, {name = "__EVENTTARGET", value = ""}) end
  if not seen["__EVENTARGUMENT"] then table.insert(fields, {name = "__EVENTARGUMENT", value = ""}) end

  local body = {}
  for _, f in ipairs(fields) do
    local v = f.value
    if f.name == "__EVENTTARGET" then v = target end
    table.insert(body, MM.urlencode(f.name) .. "=" .. MM.urlencode(v))
  end

  dbg("Nutzungsbedingungen: Zustimmen an " .. url .. " (" .. #fields .. " Felder)")
  local result = request("POST", url, table.concat(body, "&"),
                         "application/x-www-form-urlencoded",
                         {["Origin"] = BASE, ["Referer"] = url})
  return result, nil
end

-- Vom aktuellen Seiteninhalt aus bis zum Dashboard laufen.
-- Liefert ("token", rvToken) | ("terms", html) | ("fail", nil)
local function walkToPortal (content)
  for hop = 1, 8 do
    if type(content) ~= "string" then return "fail", nil end

    local token = extractRvToken(content)
    if token ~= nil then return "token", token end

    if isTermsPage(content) then return "terms", content end

    -- OAuth2-form_post (id_token/code/state) automatisch absenden
    if content:find('name="id_token"', 1, true) or content:find('name="code"', 1, true)
       or content:find('name="state"', 1, true) then
      local html = HTML(content)
      local form = html:xpath("//form")
      if form:length() == 0 then return "fail", nil end
      dbg("form_post absenden (Schritt " .. hop .. ")")
      content = request(form:submit())
    elseif hop == 1 then
      content = request("GET", DASHBOARD)
    else
      return "fail", nil
    end
  end
  return "fail", nil
end

-- Nach erfolgreichem ForgeRock-Login: Portal oeffnen.
-- Liefert ("ok") | ("terms", html) | ("fail")
local function openPortal (auth)
  MM.printStatus("Portal oeffnen")

  local function try (content)
    local state, payload = walkToPortal(content)
    if state == "token" then rvToken = payload end
    return state, payload
  end

  -- 1. Weg wie der Browser: successUrl (OAuth2-Code-Flow des Auth-Service),
  --    der ueber start.aspx zum form_post des Portals fuehrt
  local su = auth and auth["successUrl"]
  if type(su) == "string" and su:find("oauth2", 1, true) then
    local ok, c = pcall(function () return (request("GET", su)) end)
    if ok and type(c) == "string" and c ~= "" then
      local state, payload = try(c)
      if state ~= "fail" then return state == "token" and "ok" or state, payload end
    end
  end

  -- 2. Weg: Portal-Einstieg (loest mit SSO-Cookie denselben form_post aus)
  local state, payload = try(request("GET", BASE .. "/"))
  if state ~= "fail" then return state == "token" and "ok" or state, payload end

  -- 3. Weg: Dashboard direkt
  state, payload = try(request("GET", DASHBOARD))
  if state ~= "fail" then return state == "token" and "ok" or state, payload end
  return "fail"
end

-- Nutzungsbedingungen gemaess TERMS_MODE behandeln.
-- Liefert nil (fertig, rvToken gesetzt), ein Dialog-Table oder einen Fehlertext.
-- Bestaetigung per Postback senden und bis zum Dashboard laufen.
-- Liefert nil (fertig, rvToken gesetzt) oder einen Fehlertext.
local function acceptAndOpen (page, how)
  local result, err = acceptTerms(page)
  if err then return "Nutzungsbedingungen konnten nicht bestaetigt werden: " .. err end
  local state, payload = walkToPortal(result)
  if state ~= "token" then
    state, payload = walkToPortal(request("GET", DASHBOARD))
  end
  if state == "token" then
    rvToken = payload
    print("Nutzungsbedingungen bestaetigt (" .. how .. ").")
    return nil
  end
  if state == "terms" then
    return "ERGO hat die Zustimmung nicht uebernommen. Bitte im Browser unter " ..
           "kunde-s.ergo.de anmelden und dort zustimmen."
  end
  return "Nutzungsbedingungen bestaetigt, aber das Portal liefert keine Sitzung."
end

-- Ohne Zustimmung weiterversuchen; erst bei Misserfolg den Hinweis liefern.
local function tryWithoutTerms (text)
  local state, payload = walkToPortal(request("GET", DASHBOARD))
  if state == "token" then rvToken = payload; return nil end
  return "ERGO verlangt die Zustimmung zu geaenderten Nutzungsbedingungen; ohne " ..
         "sie ist das Kundenportal gesperrt. Zustimmen: beim naechsten " ..
         "Aktualisieren im Dialog \"ja\" eingeben oder im Browser unter " ..
         "kunde-s.ergo.de.\n\n" .. text
end

-- Nutzungsbedingungen gemaess TERMS_MODE behandeln.
-- Liefert nil (fertig, rvToken gesetzt), ein Dialog-Table oder einen Fehlertext.
local function handleTerms (page, interactive)
  local text = termsText(page)
  print("ERGO verlangt Zustimmung zu geaenderten Nutzungsbedingungen:")
  print((text:gsub("\n+", " | ")))

  if TERMS_MODE == "auto" then
    return acceptAndOpen(page, "automatisch, TERMS_MODE = auto")
  end

  if TERMS_MODE == "never" or interactive == false then
    return tryWithoutTerms(text)
  end

  -- "ask": in MoneyMoney vorlegen
  pending = {kind = "terms", page = page}
  return {
    title     = "ERGO Kundenportal: Nutzungsbedingungen",
    challenge = text .. "\n\nZum Zustimmen bitte \"ja\" eingeben. Jede andere " ..
                "Eingabe lehnt ab; der Abruf wird dann ohne Zustimmung versucht.",
    label     = "Zustimmen? (ja/nein)"
  }
end

local function isYes (s)
  s = tostring(s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  return s == "ja" or s == "j" or s == "yes" or s == "y" or s == "ok"
      or s == "zustimmen" or s == "akzeptieren" or s == "1" or s == "true"
end

-- Nach ForgeRock-Erfolg: Portal oeffnen und Nutzungsbedingungen behandeln.
-- Liefert nil (fertig), Dialog-Table oder Fehlertext.
local function completeLogin (auth, interactive)
  local state, page = openPortal(auth)
  if state == "ok" then return nil end
  if state == "terms" then return handleTerms(page, interactive) end
  return "Anmeldung erfolgreich, aber das Kundenportal hat keine Sitzung geliefert."
end

-- ---------------------------------------------------------------------------
-- Datenabruf
-- ---------------------------------------------------------------------------

local function apiCall (payload)
  if rvToken == nil then
    error("Nicht angemeldet: kein __RequestVerificationToken vorhanden.")
  end
  return postJSON(API_URL, payload, {
    ["Accept"]                     = "application/json",
    ["X-Requested-With"]           = "XMLHttpRequest",
    ["__RequestVerificationToken"] = rvToken,
    ["Origin"]                     = BASE
  })
end

-- Zweite Vertragsquelle: REST-Endpunkt des Vertragslisten-Widgets.
-- Auth laeuft ueber die domain-weiten Session-Cookies, die MoneyMoney nach
-- dem Login bereits haelt (kein Bearer-Token noetig, per HAR bestaetigt).
-- Gibt (geparste Daten oder nil, Rohtext oder nil) zurueck.
local function fetchAppsContracts ()
  local ok, content = pcall(function ()
    return request("GET", APPS_URL,
                   nil, nil, {["Accept"] = "application/json", ["Origin"] = BASE})
  end)
  if not ok or content == nil or content == "" then return nil, nil end
  local ok2, data = pcall(function () return JSON(content):dictionary() end)
  if ok2 then return data, content end
  return nil, content
end

-- apps/contracts reich auswerten: vnr/verwSysSl aus detailsUrl ziehen und
-- Zusatzinfos (Produkt, Inhaber, Gesellschaft, Status, Waehrung, bankBalance)
-- in contractMeta ablegen. Faellt bei unerwarteter Struktur auf die generische
-- Erkennung zurueck.
local function harvestApps (data, out, seen)
  if type(data) ~= "table" or type(data["contracts"]) ~= "table" then
    findContracts(data, out, seen)
    return
  end
  for _, c in ipairs(data["contracts"]) do
    if type(c) == "table" then
      local url = c["detailsUrl"] or ""
      local vnr = url:match("[?&]vnr=([^&]+)")
      local sys = url:match("[?&]verwSysSl=([^&]+)")
      if vnr and sys then
        vnr = MM.urldecode(vnr)
        sys = MM.urldecode(sys)
        collectContract(out, seen, vnr, sys)
        local pay  = type(c["payment"]) == "table" and c["payment"] or {}
        local risk = type(c["insuredRisk"]) == "table" and c["insuredRisk"] or {}
        contractMeta[normalizeVnr(vnr)] = {
          product     = cleanText(c["insuranceType"]),
          company     = cleanText(c["displayCompany"]),
          status      = c["contractStatus"],
          owner       = cleanText(risk["riskName"]),
          currency    = pay["currency"],
          bankBalance = c["bankBalance"]
        }
      else
        findContracts(c, out, seen)
      end
    end
  end
end

-- Antworttext gekuerzt und einzeilig ins Protokoll schreiben (nur bei DEBUG)
local function logRaw (label, raw)
  if not DEBUG then return end
  local n = 0
  if type(raw) == "string" then n = #raw end
  local preview = "(leer)"
  if n > 0 then preview = raw:sub(1, 220):gsub("%s+", " ") end
  print(string.format("Quelle %-18s %5d B :: %s", label, n, preview))
end

local function ensureContracts ()
  if contracts ~= nil then return contracts end

  MM.printStatus("Vertraege abrufen")
  local out, seen = {}, {}

  local function harvest (label, node, raw)
    logRaw(label, raw)
    if node ~= nil then findContracts(node, out, seen) end
    dbg(string.format("  -> %d Vertrag(e) gesamt nach %s", #out, label))
  end

  -- Quelle 1: sauberer REST-Endpunkt (Cookie-Auth), aktuelle Primaerquelle
  local appsData, appsRaw = fetchAppsContracts()
  logRaw("apps/contracts", appsRaw)
  harvestApps(appsData, out, seen)
  dbg(string.format("  -> %d Vertrag(e) gesamt nach apps/contracts", #out))

  -- Quelle 2: klassischer SPA-Aufruf (in neueren Portalstaenden leer)
  if #out == 0 then
    local d = apiCall({contractList = true})
    harvest("spa/contractList", d, lastRawResponse)
  end

  -- Quelle 3: gerenderte Seiteninhalte -- enthaelt teils detailsUrls
  if #out == 0 then
    local d = apiCall({pageContent = {{pageName = "ContractsList"}}, customer = true})
    harvest("spa/pageContent", d, lastRawResponse)
  end

  -- Quelle 4: Postfach-Dashboard -- vnr/verwSysSl je Nachricht
  if #out == 0 then
    local d = apiCall({inbox = {dashboardList = true, unreadCount = true}})
    harvest("spa/dashboardList", d, lastRawResponse)
  end

  -- Quelle 5: manuell hinterlegt
  if #out == 0 and #MANUAL_CONTRACTS > 0 then
    for _, c in ipairs(MANUAL_CONTRACTS) do
      table.insert(out, {vnr = c.vnr, verwSysSl = c.verwSysSl})
    end
    dbg("  -> " .. #out .. " Vertrag(e) aus MANUAL_CONTRACTS")
  end

  if #out == 0 then
    print("ERGO: Keine Vertraege erkannt. DEBUG=true setzen und Protokoll pruefen.")
  end

  contracts = out
  dbg("Gefundene Vertraege: " .. #contracts)
  return contracts
end

-- Detaildaten eines Vertrags holen und aufbereiten
local function contractInfo (contract)
  local cached = detailsCache[contract.vnr]
  if cached ~= nil then return cached end

  local meta = contractMeta[normalizeVnr(contract.vnr)] or {}

  MM.printStatus("Vertrag " .. contract.vnr)
  local data = apiCall({contractDetails = {{
    verwSysSl = contract.verwSysSl,
    vnr       = contract.vnr
  }}})

  local details = nil
  if data ~= nil and type(data["contractDetails"]) == "table" then
    details = data["contractDetails"][1]
  end

  local info
  if details == nil then
    -- Details nicht abrufbar -> zumindest die apps/contracts-Basisdaten nutzen
    info = {
      vnr       = contract.vnr,
      verwSysSl = contract.verwSysSl,
      product   = meta.product or "ERGO Vertrag",
      owner     = meta.owner,
      currency  = meta.currency or "EUR",
      company   = meta.company,
      balance   = (type(meta.bankBalance) == "number") and meta.bankBalance or nil,
      balanceLabel = "Kontostand",
      funds     = {}
    }
    detailsCache[contract.vnr] = info
    return info
  end

  local fields = details["dataFields"]
  local funds = {}
  findFunds(fields, funds)
  for _, f in ipairs(funds) do f.name = cleanText(f.name) or f.isin end

  local balance, balanceLabel = findBalance(fields)
  if balance == nil and type(meta.bankBalance) == "number" then
    balance, balanceLabel = meta.bankBalance, "Kontostand"
  end

  info = {
    vnr          = contract.vnr,
    verwSysSl    = contract.verwSysSl,
    product      = cleanText(fieldValue(fields, "Produkt"))
                   or cleanText(fieldValue(fields, "Produktname"))
                   or meta.product
                   or "ERGO Vertrag",
    owner        = meta.owner,
    currency     = meta.currency or "EUR",
    company      = meta.company,
    balance      = balance,
    balanceLabel = balanceLabel or "Vertragsguthaben",
    funds        = funds
  }

  detailsCache[contract.vnr] = info
  return info
end

-- ---------------------------------------------------------------------------
-- Einsprungspunkte
-- ---------------------------------------------------------------------------

function SupportsBank (protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "ERGO Kundenportal"
end

function InitializeSession2 (protocol, bankCode, step, credentials, interactive)
  -- Offener Dialog: Zustimmung zu Nutzungsbedingungen
  if step > 1 and pending ~= nil and pending.kind == "terms" then
    local page = pending.page
    pending = nil
    if isYes(credentials[1]) then
      MM.printStatus("Nutzungsbedingungen bestaetigen")
      return acceptAndOpen(page, "in MoneyMoney")
    end
    print("Nutzungsbedingungen im Dialog nicht bestaetigt -- Abruf ohne Zustimmung wird versucht.")
    return tryWithoutTerms(termsText(page))
  end

  local status, payload

  if step == 1 then
    MM.printStatus("Anmeldung bei ERGO")
    pending = nil
    notices = {}

    -- Zugangsdaten aus dem credentials-Array holen (positionsbasiert), mit
    -- benannten Feldern als Rueckfallebene, falls MoneyMoney anders liefert.
    local username = credentials[1]
    local password = credentials[2]
    if type(username) ~= "string" or username == "" then
      username = credentials["username"] or credentials["user"] or username
    end
    if type(password) ~= "string" or password == "" then
      password = credentials["password"] or credentials["pass"] or password
    end
    dbg("credentials-Array: " .. tostring(#credentials) .. " Eintrag/Eintraege")
    if type(username) ~= "string" or username == ""
       or type(password) ~= "string" or password == "" then
      print("Benutzername oder Passwort fehlt.")
      return LoginFailed
    end

    -- Redirect-Kette zum Login-Endpunkt aufbauen (setzt die noetigen Cookies)
    request("GET", BASE .. "/")

    local auth = postJSON(AUTH_URL, nil, JSON_HEADERS)
    if auth == nil or auth["callbacks"] == nil then
      return "Login-Dialog von ERGO konnte nicht geladen werden."
    end

    status, payload = runAuthTree(auth, {username = username, password = password})
  else
    -- Antwort auf den SMS-Code-Dialog
    if pending == nil or pending.kind ~= "otp" then
      return "Kein offener Anmeldevorgang -- bitte das Konto erneut aktualisieren."
    end
    local auth = pending.auth
    pending = nil
    MM.printStatus("SMS-Code pruefen")
    status, payload = runAuthTree(auth, {code = tostring(credentials[1] or "")})
  end

  if status == "prompt" then
    pending = {kind = "otp", auth = payload.auth}
    if interactive == false then
      return "ERGO verlangt bei jeder Anmeldung einen SMS-Code. Eine Aktualisierung " ..
             "im Hintergrund ist daher nicht moeglich -- bitte das Konto manuell " ..
             "aktualisieren und den Code eingeben."
    end
    local text = noticesText() .. (payload.text or "")
    if text == "" then text = "Bitte den Code eingeben, den ERGO Ihnen gesendet hat." end
    return {
      title     = "ERGO Kundenportal: " .. (payload.label or "Code"),
      challenge = text,
      label     = payload.label or "Code"
    }
  end

  if status == "failed" then
    local msg = tostring(payload)
    local m401 = msg:match("^401:(.*)$")
    if m401 then
      if step == 1 then
        print("ForgeRock lehnte die Zugangsdaten ab (401, message=" .. m401 .. ").")
        print("Der ERGO-Benutzername ist der bei der Registrierung gewaehlte Name, " ..
              "nicht die Versicherungsnummer. Zum Test im Browser auf kunde-s.ergo.de " ..
              "mit exakt diesen Daten anmelden.")
        return LoginFailed
      end
      return "ERGO hat den SMS-Code abgelehnt (abgelaufen oder falsch). Bitte das " ..
             "Konto erneut aktualisieren und den neuen Code eingeben."
    end
    print(msg)
    if step == 1 then return LoginFailed end
    return msg
  end

  -- status == "ok": SSO-Token vorhanden -> Portal oeffnen
  return completeLogin(payload, interactive)
end

function ListAccounts (knownAccounts)
  local accounts = {}

  for _, contract in ipairs(ensureContracts()) do
    local info = contractInfo(contract)
    local hasValue = (info ~= nil and info.balance ~= nil)
    if info ~= nil and (hasValue or INCLUDE_ALL_CONTRACTS) then
      -- Depot nur, wenn ein Wert vorliegt (sonst gaebe es nichts zu bebuchen)
      local isPortfolio = PORTFOLIO_MODE and hasValue

      local name = info.product or "ERGO Vertrag"
      if info.company and info.company ~= ""
         and not name:upper():find(info.company:upper(), 1, true) then
        name = info.company .. " " .. name
      end

      table.insert(accounts, {
        name          = name,
        owner         = info.owner,
        accountNumber = info.vnr,
        currency      = info.currency or "EUR",
        portfolio     = isPortfolio,
        type          = isPortfolio and AccountTypePortfolio or AccountTypeOther
      })
    end
  end

  if #accounts == 0 then
    return "Es wurde kein Vertrag mit Guthaben gefunden."
  end
  return accounts
end

function RefreshAccount (account, since)
  local match = nil
  local wanted = normalizeVnr(account.accountNumber)
  local candidates = ensureContracts()
  for _, contract in ipairs(candidates) do
    if normalizeVnr(contract.vnr) == wanted then match = contract end
  end
  -- Fallback: bei genau einem Vertrag diesen verwenden
  if match == nil and #candidates == 1 then match = candidates[1] end

  if match == nil then
    return "Vertrag " .. tostring(account.accountNumber) ..
           " ist im Kundenportal nicht mehr vorhanden."
  end

  local info = contractInfo(match)
  if info == nil then
    return "Vertragsdaten zu " .. tostring(account.accountNumber) ..
           " konnten nicht gelesen werden."
  end

  local currency = info.currency or "EUR"
  local asPortfolio = account.portfolio or (PORTFOLIO_MODE and info.balance ~= nil)

  if asPortfolio then
    if info.balance == nil then
      return {securities = {}}
    end

    local securities, sum = {}, 0
    for _, f in ipairs(info.funds) do
      sum = sum + f.amount
      table.insert(securities, {
        name     = f.name,
        isin     = f.isin,
        amount   = f.amount,
        currency = currency
      })
    end

    if #securities == 0 then
      -- Klassischer Vertrag ohne Fonds: eine synthetische Position, damit
      -- MoneyMoney den Wertverlauf als Depot fuehren kann.
      table.insert(securities, {
        name     = info.balanceLabel or "Vertragsguthaben",
        amount   = info.balance,
        currency = currency
      })
    else
      local rest = info.balance - sum
      if rest > 0.005 or rest < -0.005 then
        table.insert(securities, {
          name     = "Sonstiges Guthaben",
          amount   = rest,
          currency = currency
        })
      end
    end
    return {securities = securities}
  end

  return {balance = info.balance or 0, transactions = {}}
end

function EndSession ()
  pcall(function () request("GET", LOGOUT) end)
  if connection ~= nil then
    pcall(function () connection:close() end)
    connection = nil
  end
  rvToken      = nil
  contracts    = nil
  contractMeta = {}
  detailsCache = {}
  pending      = nil
  notices      = {}
  return nil
end

dbg("ERGO Kundenportal Extension geladen (v1.08)")
