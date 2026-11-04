-- ERGO-Kundenportal.lua
--
-- MoneyMoney Web Banking Extension fuer das ERGO Kundenportal
-- "Meine Versicherungen" (kunde-s.ergo.de). Deckt ERGO- und DKV-Vertraege ab.
--
-- Liest alle Vertraege des Kontos aus und legt fuer jeden Vertrag mit Wert
-- ein Konto/Depot in MoneyMoney an. Nichts ist fest verdrahtet: weder
-- Vertragsnummern noch ISINs noch Produktnamen -- alles wird generisch aus
-- der ERGO-JSON-API gelesen. Anmeldedaten sind Benutzername und Passwort
-- des ERGO Kundenportals.
--
-- FUNKTIONSWEISE
--   1. GET kunde-s.ergo.de -> Redirect-Kette zum ForgeRock-Login (ciam.ergo.com)
--   2. POST /am/json/.../authenticate (leer)      -> authId + Callbacks
--   3. POST /am/json/.../authenticate (befuellt)  -> tokenId, SSO-Cookie
--      (zweiter Faktor wird unterstuetzt, falls das Konto ihn verlangt)
--   4. OAuth2-form_post-Formulare automatisch absenden bis zum Dashboard
--   5. __RequestVerificationToken aus dem HTML ziehen
--   6. GET apps.kunde-s.ergo.de/prod/api/v1/contracts  -> Vertragsliste
--   7. POST /meineversicherungen/L1/api/spa {"contractDetails":[{...}]}
--      -> Guthaben und Fondspositionen aus dem dataFields-Baum
--
-- INSTALLATION
--   Signierte Version: einfach in den Extensions-Ordner legen.
--   Unsigniert (Eigenbau): MoneyMoney > Einstellungen > Extensions >
--     "Digitale Signatur von Extensions ueberpruefen" deaktivieren.
--   Ordner oeffnen: MoneyMoney > Hilfe > Datenbank im Finder zeigen.
--   Danach: Konto hinzufuegen > Andere > ERGO Kundenportal
--
-- Fehlersuche: DEBUG unten auf true setzen, dann Fenster > Protokollfenster.
-- Lizenz: MIT. Ohne Gewaehr, keine Verbindung zur ERGO Group AG.

WebBanking{
  version     = 1.07,
  url         = "https://kunde-s.ergo.de/",
  services    = {"ERGO Kundenportal"},
  description = "Vertragsguthaben und Fondsdepots aus dem ERGO Kundenportal (ERGO/DKV)"
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

-- true : ausfuehrliche Protokollausgaben (Rohantworten, Feldlaengen der
--        Zugangsdaten, Quellen-Trefferzahlen). Fuer den Normalbetrieb aus,
--        fuer die Fehlersuche an. Fehlermeldungen erscheinen immer.
local DEBUG = false

local BASE     = "https://kunde-s.ergo.de"
local CIAM     = "https://ciam.ergo.com"
local APPS_URL = "https://apps.kunde-s.ergo.de/prod/api/v1/contracts"
local AUTH_URL = CIAM .. "/am/json/realms/root/realms/customerportal/authenticate"
local API_URL  = BASE .. "/meineversicherungen/L1/api/spa"
local LOGOUT   = CIAM .. "/am/UI/Logout?realm=/customerportal"

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

local function dbg (...) if DEBUG then print(...) end end

-- ---------------------------------------------------------------------------
-- Zustand
-- ---------------------------------------------------------------------------

local connection   = nil
local rvToken      = nil
local contracts    = nil   -- { {vnr=, verwSysSl=}, ... }
local contractMeta = {}    -- normVnr -> {product, owner, company, status, currency, bankBalance}
local detailsCache = {}    -- vnr -> geparste Detaildaten
local pendingAuth  = nil   -- fuer optionalen zweiten Faktor

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

-- Request mit defensiver Redirect-Verfolgung. MoneyMoney folgt Redirects in
-- der Regel selbst; falls nicht, uebernimmt das diese Schleife.
local function request (method, url, body, contentType, headers)
  local content, charset, mimeType, filename, respHeaders =
    conn():request(method, url, body, contentType, headers)

  local hops = 0
  while hops < 10 do
    local loc = headerValue(respHeaders, "location")
    if loc == nil or loc == "" then break end
    hops = hops + 1
    content, charset, mimeType, filename, respHeaders =
      conn():request("GET", loc, nil, nil, headers)
  end

  return content, charset, mimeType, respHeaders
end

local JSON_HEADERS = {
  ["Accept"]           = "application/json",
  ["Accept-API-Version"] = "protocol=1.0,resource=2.1",
  ["X-Requested-With"] = "forgerock-sdk"
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
-- Anmeldung
-- ---------------------------------------------------------------------------

-- Formulare der OAuth2-form_post-Antworten absenden, bis das Portal antwortet
local function followFormPost (content)
  local hops = 0
  while hops < 6 do
    if content == nil then return nil end

    local token = content:match('name="__RequestVerificationToken"[^>]-value="([^"]*)"')
                  or content:match('value="([^"]*)"[^>]-name="__RequestVerificationToken"')
    if token ~= nil and token ~= "" then return token end

    local html = HTML(content)
    local form = html:xpath("//form")
    if form:length() == 0 then return nil end

    hops = hops + 1
    content = request(form:submit())
  end
  return nil
end

local function fetchRequestVerificationToken ()
  local content = request("GET", BASE .. "/")
  local token = followFormPost(content)
  if token == nil then
    content = request("GET", BASE .. "/meineversicherungen/L1/Startseite/Dashboard.aspx")
    token = followFormPost(content)
  end
  return token
end

-- Callbacks typbasiert befuellen: NameCallback -> Benutzername,
-- PasswordCallback -> Passwort. Robuster als reine Reihenfolge.
-- Loggt, OB die Felder befuellt wurden (Laenge, nicht der Wert) -- zur
-- Unterscheidung "falsche Zugangsdaten" vs. "leere Felder uebergeben".
local function submitCredentials (auth, username, password)
  for _, cb in ipairs(auth["callbacks"] or {}) do
    local t = cb["type"]
    for _, inp in ipairs(cb["input"] or {}) do
      if t == "PasswordCallback" then
        inp["value"] = password
      elseif t == "NameCallback" then
        inp["value"] = username
      end
    end
  end

  for _, cb in ipairs(auth["callbacks"] or {}) do
    for _, inp in ipairs(cb["input"] or {}) do
      local v = inp["value"]
      local filled = (type(v) == "string" and v ~= "")
      dbg(string.format("  %s.%s befuellt: %s (%d Zeichen)",
        tostring(cb["type"]), tostring(inp["name"]),
        filled and "ja" or "NEIN", (type(v) == "string") and #v or 0))
    end
  end

  return postJSON(AUTH_URL, auth, JSON_HEADERS)
end

-- Antwort auf einen weiteren Faktor (Reihenfolge, da generisch)
local function submitCallbacks (auth, values)
  local i = 1
  for _, cb in ipairs(auth["callbacks"] or {}) do
    for _, inp in ipairs(cb["input"] or {}) do
      if values[i] ~= nil then
        inp["value"] = values[i]
        i = i + 1
      end
    end
  end
  return postJSON(AUTH_URL, auth, JSON_HEADERS)
end

-- Prompt des naechsten Callbacks fuer die Anzeige in MoneyMoney
local function callbackPrompt (auth)
  for _, cb in ipairs(auth["callbacks"] or {}) do
    for _, out in ipairs(cb["output"] or {}) do
      if out["name"] == "prompt" and type(out["value"]) == "string" then
        return out["value"]
      end
    end
  end
  return "Bestaetigungscode"
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
    local d = apiCall({dashboardList = true, unreadCount = true})
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
  local auth

  if step == 1 then
    MM.printStatus("Anmeldung bei ERGO")

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

    -- Redirect-Kette zum Login-Endpunkt aufbauen (setzt die noetigen Cookies)
    request("GET", BASE .. "/")

    auth = postJSON(AUTH_URL, nil, JSON_HEADERS)
    if auth == nil or auth["callbacks"] == nil then
      return "Login-Dialog von ERGO konnte nicht geladen werden."
    end

    auth = submitCredentials(auth, username, password)
  else
    if pendingAuth == nil then return "Kein offener Anmeldevorgang." end
    auth = submitCallbacks(pendingAuth, {credentials[1]})
    pendingAuth = nil
  end

  if auth == nil then
    return "Keine Antwort vom Anmeldeserver."
  end

  -- Zweiter Faktor angefordert
  if auth["callbacks"] ~= nil and auth["tokenId"] == nil then
    pendingAuth = auth
    return {
      title     = "ERGO Kundenportal",
      challenge = auth["description"] or callbackPrompt(auth),
      label     = callbackPrompt(auth)
    }
  end

  if auth["tokenId"] == nil then
    local code = auth["code"]
    local msg  = auth["message"]
    if code == 401 or code == "401" then
      print("ForgeRock lehnte die Zugangsdaten ab (code 401, message=" ..
            tostring(msg) .. ").")
      print("Falls die obigen Callback-Zeilen 'ja (>0 Zeichen)' zeigen, " ..
            "stimmen Benutzername/Passwort nicht -- der ERGO-Benutzername " ..
            "ist der bei der Registrierung gewaehlte Name, nicht die " ..
            "Versicherungsnummer. Zum Test im Browser auf kunde-s.ergo.de " ..
            "mit exakt diesen Daten anmelden.")
      return LoginFailed
    end
    if msg ~= nil then
      print("Anmeldefehler: " .. tostring(msg))
      return LoginFailed
    end
    return LoginFailed
  end

  MM.printStatus("Portal oeffnen")
  rvToken = fetchRequestVerificationToken()
  if rvToken == nil then
    return "Anmeldung erfolgreich, aber das Kundenportal hat keine Sitzung geliefert."
  end

  return nil
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
  return nil
end

dbg("ERGO Kundenportal Extension geladen (v1.07)")

-- SIGNATURE: MC0CFQCJM//fOnkT54wh5XSzWmZ8AHPjoAIUe6f5tBewLWIJNixhon09oSMMOic=
