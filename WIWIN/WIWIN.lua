-- WIWIN.lua
--
-- MoneyMoney Web Banking Extension fuer WIWIN Crowdinvesting.
--
-- WICHTIG -- richtiger Login-Weg:
--   Diese Extension nutzt AUSSCHLIESSLICH das WIWIN-Investoren-Kundenportal
--   unter  https://invest.wiwin.de/  (technisch betrieben ueber den Partner
--   Portagon). Ueber genau diesen Weg werden auch die Investitionen angezeigt,
--   die nur im Kundenportal sichtbar sind.
--   NICHT geeignet fuer den separaten Login unter wiwin-invest.de / wiwin.de.
--   Zugangsdaten = E-Mail und Passwort des invest.wiwin.de-Kontos.
--
-- Bildet das Portfolio als Depot bei der Baader Bank ab: eine Position je
-- Investition (aktueller Bestandswert, inkl. ISIN, Finanzinstrument, Kaufdatum,
-- Vertragsnummer) und optional das Guthaben des Verrechnungskontos (auch
-- negativ, z.B. nach Gebuehrenbelastung). Nichts ist fest verdrahtet --
-- Projekte, Betraege, IDs, ISINs, Bankdaten werden aus den Portalseiten
-- gelesen; funktioniert daher auch mit vielen oder andersartigen Positionen.
--
-- FUNKTIONSWEISE
--   1. GET  /investor/login                    -> CSRF-Token (authenticity_token)
--   2. POST /investor/login                    -> Session-Cookie (Rails/Devise)
--   3. GET  /investor/account/investments?status=active&page=N
--        (alle Seiten; optional auch status=finished) -> Tabelle mit ID,
--        Projekt, Vertragsnummer, Investitionsbetrag, Datum, Status
--   4. GET  /investor/account/investments/ID   -> Detaildaten (Bestandswert,
--        ISIN, Emittent, Finanzinstrument); bei Fehler Rueckfall auf Zeile aus 3
--   5. GET  /investor/account/account_balance.turbo_stream -> Guthaben + IBAN
--   6. GET  /investor/account/overview -> Gesamt-Bestandswert des Portals als
--        Plausibilitaetspruefung gegen die Summe der Positionen (nur Warnung)
--
-- MoneyMoney speichert den Depotbestand bei jedem Rundruf lokal -> Wertverlauf
-- ab sofort (kein rueckwirkender Verlauf moeglich).
--
-- Nicht im Portal-HTML enthalten (nur im Zeichnungsschein-PDF): Stueckzahl und
-- Stueckpreis. Werden gesetzt, sobald eine Investition sie anzeigt; sonst wird
-- der Gesamtwert (Bestandswert) gefuehrt.
--
-- INSTALLATION
--   Signierte Version: einfach in den Extensions-Ordner legen.
--   Unsigniert (Eigenbau): MoneyMoney > Einstellungen > Extensions >
--     "Digitale Signatur von Extensions ueberpruefen" deaktivieren.
--   Ordner: MoneyMoney > Hilfe > Datenbank im Finder zeigen > "Extensions".
--   Danach: Konto hinzufuegen > Andere > WIWIN Crowdinvesting
--
-- Fehlersuche: DEBUG unten auf true setzen, dann Fenster > Protokollfenster.
-- Lizenz: CC0 1.0 (Public-Domain-Freigabe). Soweit rechtlich moeglich, wird
-- auf alle Urheber- und verwandten Rechte an dieser Software verzichtet. Sie
-- wird OHNE JEDE GEWAEHR bereitgestellt. Lizenztext:
-- https://creativecommons.org/publicdomain/zero/1.0/
-- Keine Verbindung zur WIWIN GmbH, Portagon, Baader Bank oder MRH applications.

WebBanking{
  version     = 1.05,
  url         = "https://invest.wiwin.de/investor/login",
  services    = {"WIWIN Crowdinvesting"},
  -- Die Beschreibung erscheint im Kontoeinrichtungs-Dialog direkt bei der
  -- Eingabe der Zugangsdaten -- der naechstmoegliche Ort fuer einen Hinweis
  -- (MoneyMoney bietet keinen eigenen Popup-Mechanismus beim Login).
  description = "Portfolio aus dem WIWIN-Kundenportal invest.wiwin.de (Partner Portagon). " ..
                "Nur fuer diesen Login-Weg -- NICHT fuer wiwin-invest.de. " ..
                "Zugangsdaten: E-Mail und Passwort von invest.wiwin.de."
}

-- ---------------------------------------------------------------------------
-- Konfiguration
-- ---------------------------------------------------------------------------

-- Guthaben des Verrechnungskontos (Baader Bank) mit abbilden. Auch ein
-- negativer Stand (z.B. -0,29 EUR nach Gebuehrenbelastung) wird uebernommen.
local INCLUDE_CASH = true

-- Guthaben als EIGENES Konto (Girokonto mit IBAN) statt als Position im Depot.
-- Sinnvoll, wenn das Verrechnungskonto regelmaessig bewegt wird oder negativ ist.
local SEPARATE_CASH_ACCOUNT = false

-- Auch beendete / vollstaendig zurueckgezahlte Investitionen abrufen
-- (Portal-Filter "beendete Investitionen"). Standard aus.
local INCLUDE_REPAID = false

-- Zusatzinfos (Finanzinstrument, Vertragsnummer) an den Positionsnamen
-- anhaengen. Die ISIN steht ohnehin im eigenen Feld der Depotposition.
local RICH_NAMES = true

-- Detailseite je Investition laden (liefert Bestandswert, ISIN, Emittent).
-- false: nur die Listenseite verwenden (schneller; Wert = Investitionsbetrag,
-- keine ISIN). Bei Fehlern auf der Detailseite wird automatisch die Zeile
-- der Liste verwendet.
local FETCH_DETAILS = true

-- Ausfuehrliche Protokollausgaben zur Fehlersuche. Standard aus.
local DEBUG = false

local BASE         = "https://invest.wiwin.de"
local LOGIN_URL    = BASE .. "/investor/login"
local INVEST_LIST  = BASE .. "/investor/account/investments"
local BALANCE_URL  = BASE .. "/investor/account/account_balance.turbo_stream"
local OVERVIEW_URL = BASE .. "/investor/account/overview"

local CURRENCY      = "EUR"
local DEPOT_NUMBER  = "WIWIN-PORTFOLIO"
local CASH_NUMBER   = "WIWIN-CASH"
local MAX_PAGES     = 50      -- Sicherheitsgrenze fuer die Seitenschleife
local ITEMS_PER_PAGE = 50     -- Portal-Standard ist 10; weniger Requests

-- Feldbezeichnungen fuer den aktuellen Positionswert (Reihenfolge = Prioritaet).
-- Deckt Aktie, Nachrangdarlehen, Fonds/ELTIF ab; erweiterbar.
local VALUE_LABELS = {
  "Bestandswert",
  "Aktueller Wert",
  "Aktueller Bestandswert",
  "Anlagebetrag",
  "Anlagesumme",
  "Nominalbetrag",
  "Investitionsbetrag"
}

-- ---------------------------------------------------------------------------
-- Zustand
-- ---------------------------------------------------------------------------

local connection = nil
local portfolio  = nil

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

local function dbg (...) if DEBUG then print(...) end end

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

local function resolveLocation (base, loc)
  if loc:match("^https?://") then return (loc:gsub("^http://", "https://")) end
  local origin = base:match("^(https?://[^/]+)") or BASE
  if loc:sub(1, 1) == "/" then return origin .. loc end
  return origin .. "/" .. loc
end

-- Request mit defensiver Redirect-Verfolgung (MoneyMoney folgt meist selbst)
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

  return content, respHeaders
end

-- GET, der bei Netz-/Serverfehler nil statt eines Lua-Fehlers liefert
local function safeGet (url, headers)
  local ok, content = pcall(function () return (request("GET", url, nil, nil, headers)) end)
  if ok and type(content) == "string" and content ~= "" then return content end
  dbg("Abruf fehlgeschlagen: " .. url)
  return nil
end

-- ---------------------------------------------------------------------------
-- Parser-Hilfsfunktionen
-- ---------------------------------------------------------------------------

local function decodeEntities (s)
  if type(s) ~= "string" then return s end
  s = s:gsub("&nbsp;", " "):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&apos;", "'")
       :gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&minus;", "-"):gsub("&euro;", "€")
  if utf8 and utf8.char then
    s = s:gsub("&#(%d+);", function (n)
      local ok, c = pcall(utf8.char, tonumber(n))
      return ok and c or ""
    end)
  end
  return (s:gsub("&amp;", "&"))
end

local function trim (s)
  return (tostring(s or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Sichtbaren Text aus einem HTML-Fragment ziehen
local function textOf (s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("<svg.-</svg>", ""):gsub("<[^>]*>", " ")
  s = trim(decodeEntities(s))
  if s == "" then return nil end
  return s
end

-- "1.234,56 €" / "-0,29" / "−0,29" / "- 12,00" -> Zahl ; sonst nil.
-- Vorzeichen wird uebernommen (typografisches Minus U+2212 eingeschlossen).
local function parseEuro (s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("\226\136\146", "-")                 -- U+2212 MINUS SIGN
  local sign, int, dec = s:match("([%-%+]?)%s*([%d%.]+),(%d%d)")
  if not int then return nil end
  local n = tonumber((int:gsub("%.", "")) .. "." .. dec)
  if n == nil then return nil end
  if sign == "-" then n = -n end
  return n
end

-- Ersten Geldbetrag NACH einer Beschriftung finden (Euro-Zeichen optional,
-- darf in eigenem span stehen; Vorzeichen wird erfasst).
local function moneyAfter (html, label)
  local pat = label:gsub("(%W)", "%%%1") .. ".-([%-\226\136\146]?%s*[%d%.]+,%d%d)"
  return parseEuro(html:match(pat) or "")
end

-- Wert einer Detailzeile: <strong>LABEL</strong> ... fw-bold> WERT </...
local function detailField (html, label)
  local pat = "<strong>%s*" .. label:gsub("(%W)", "%%%1") ..
              "%s*</strong>.-fw%-bold[^>]*>%s*(.-)%s*</"
  local v = html:match(pat)
  if v == nil then return nil end
  return textOf(v)
end

-- "08.07.26" / "08.07.2026" -> POSIX ; sonst nil
local function parseDate (s)
  if type(s) ~= "string" then return nil end
  local d, m, y = s:match("(%d%d?)%.(%d%d?)%.(%d%d%d?%d?)")
  if not d then return nil end
  y = tonumber(y); if y < 100 then y = 2000 + y end
  local ok, t = pcall(os.time, {year = y, month = tonumber(m), day = tonumber(d), hour = 12})
  if ok then return t end
  return nil
end

-- Deutsche IBAN (DE + 20 Ziffern) -> iban, BLZ, Kontonummer
local function ibanParts (html)
  if type(html) ~= "string" then return nil end
  local iban = html:match("(DE" .. string.rep("%d", 20) .. ")")
  if iban == nil then return nil end
  return iban, iban:sub(5, 12), iban:sub(13, 22)
end

-- CSRF-Token aus der Login-Seite (verstecktes Feld bevorzugt, sonst <meta>)
local function extractCsrf (html)
  if type(html) ~= "string" then return nil end
  return html:match('name="authenticity_token"%s+[^>]-value="([^"]+)"')
      or html:match('value="([^"]+)"%s+[^>]-name="authenticity_token"')
      or html:match('name="csrf%-token"%s+content="([^"]+)"')
      or html:match('content="([^"]+)"%s+name="csrf%-token"')
end

-- Flash-/Fehlermeldung einer Rails-Seite (fuer das Protokoll)
local function flashMessage (html)
  if type(html) ~= "string" then return nil end
  local m = html:match('class="[^"]*alert[^"]*"[^>]*>(.-)</div>')
         or html:match('class="[^"]*flash[^"]*"[^>]*>(.-)</div>')
         or html:match('class="[^"]*toast%-body[^"]*"[^>]*>(.-)</div>')
  return textOf(m)
end

-- ---------------------------------------------------------------------------
-- Datenextraktion
-- ---------------------------------------------------------------------------

-- Zeilen der Investitionsliste parsen -> { {id, name, contractNo, invested,
-- date, status}, ... }. Spaltenreihenfolge im Portal: Projekt, Vertragsnummer,
-- Investitionsbetrag, Datum, Status.
local function parseListRows (html)
  local rows = {}
  if type(html) ~= "string" then return rows end
  -- Nicht ueber "<tr ...>" matchen: Attributwerte enthalten ">" (z.B.
  -- data-action='click->table#...'). Stattdessen am Zeilen-Link ankern und
  -- bis zum naechsten </tr> lesen.
  local pos = 1
  while true do
    local s, e, id = html:find('data%-table%-url%-value="/investor/account/investments/(%d+)"', pos)
    if s == nil then break end
    local rowEnd = html:find("</tr>", e, true) or #html
    local body = html:sub(e + 1, rowEnd - 1)
    pos = rowEnd
    local cells = {}
    for cell in body:gmatch("<td[^>]*>(.-)</td>") do table.insert(cells, cell) end
    local row = {id = id}
    if #cells >= 1 then
      row.name = textOf(cells[1]:match('title="([^"]*)"')) or textOf(cells[1])
    end
    if #cells >= 2 then row.contractNo = textOf(cells[2]) end
    if #cells >= 3 then row.invested   = parseEuro(textOf(cells[3]) or "") end
    if #cells >= 4 then row.date       = parseDate(textOf(cells[4]) or "") end
    if #cells >= 5 then row.status     = textOf(cells[5]) end
    table.insert(rows, row)
  end
  return rows
end

-- Rueckfall: nur IDs aus Links (falls das Tabellenlayout sich aendert)
local function parseListLinks (html)
  local rows, seen = {}, {}
  if type(html) ~= "string" then return rows end
  for id in html:gmatch("/investor/account/investments/(%d+)") do
    if not seen[id] then seen[id] = true; table.insert(rows, {id = id}) end
  end
  return rows
end

local function hasNextPage (html)
  if type(html) ~= "string" then return false end
  local nextItem = html:match('<li[^>]*class="[^"]*page%-item[^"]*next[^"]*"')
  if nextItem == nil then return false end
  return nextItem:find("disabled", 1, true) == nil
end

-- Alle Seiten eines Status-Filters einsammeln (dedupliziert nach ID)
local function collectList (status, out, seen)
  for page = 1, MAX_PAGES do
    local url = string.format("%s?status=%s&page=%d&items=%d", INVEST_LIST, status, page, ITEMS_PER_PAGE)
    local html = safeGet(url)
    if html == nil then break end

    local rows = parseListRows(html)
    if #rows == 0 then rows = parseListLinks(html) end
    local added = 0
    for _, r in ipairs(rows) do
      if not seen[r.id] then
        seen[r.id] = true
        r.listStatus = status
        table.insert(out, r)
        added = added + 1
      end
    end
    dbg(string.format("Liste %s Seite %d: %d Zeile(n), %d neu", status, page, #rows, added))

    if added == 0 or not hasNextPage(html) then break end
  end
end

-- Detailseite parsen und mit der Listenzeile zusammenfuehren
local function parseInvestment (html, row)
  local inv = {
    id         = row.id,
    name       = row.name,
    contractNo = row.contractNo,
    amount     = row.invested,
    date       = row.date,
    status     = row.status,
    listStatus = row.listStatus,
    source     = "Liste"
  }
  if type(html) ~= "string" then return inv end

  local h3 = textOf(html:match("<h3[^>]*>(.-)</h3>"))
  if inv.name == nil then inv.name = h3 end

  local issuer = textOf(html:match("</h3>%s*<p[^>]*>(.-)</p>"))
  if issuer and issuer ~= inv.name then inv.issuer = issuer end

  local amount = nil
  for _, label in ipairs(VALUE_LABELS) do
    amount = moneyAfter(html, label)
    if amount ~= nil then break end
  end
  if amount ~= nil then inv.amount = amount; inv.source = "Detail" end

  inv.isin       = detailField(html, "ISIN") or inv.isin
  inv.instrument = detailField(html, "Finanzinstrument")
  inv.contractNo = detailField(html, "Vertragsnummer") or inv.contractNo
  inv.status     = detailField(html, "Status") or inv.status
  inv.date       = parseDate(detailField(html, "Investitionsdatum")) or inv.date

  -- Stueckzahl / Stueckpreis, falls die Seite sie zeigt (instrumentabhaengig)
  local qty = detailField(html, "Anzahl") or detailField(html, "Stückzahl")
              or detailField(html, "Stück") or detailField(html, "Anteile")
  if qty then
    local n = (qty:match("([%d%.]+)") or ""):gsub("%.", "")
    inv.quantity = tonumber(n)
  end
  local prc = detailField(html, "Kurs") or detailField(html, "Stückpreis")
              or detailField(html, "Preis je Anteil") or detailField(html, "Zeichnungspreis")
              or detailField(html, "Ausgabepreis")
  if prc then inv.price = parseEuro(prc) end

  return inv
end

-- Guthaben + Bankdaten aus dem account_balance-Turbo-Stream.
-- Betrag steht als "-0,29 <span class='currency_symbol'>EUR</span>".
local function fetchBalance ()
  local html = safeGet(BALANCE_URL, {
    ["Accept"] = "text/vnd.turbo-stream.html, text/html",
    ["X-Requested-With"] = "XMLHttpRequest"
  })
  if html == nil then return {} end
  html = html:gsub("\226\136\146", "-")

  local raw = html:match('([%-]?%s*[%d%.]+,%d%d)%s*<span[^>]*currency_symbol')
              or html:match('([%-]?%s*[%d%.]+,%d%d)%s*<span[^>]*currency')
              or html:match('Verf.-Guthaben.-([%-]?%s*[%d%.]+,%d%d)')
              or html:match('([%-]?%s*[%d%.]+,%d%d)')

  local iban, blz, konto = ibanParts(html)
  return {cash = parseEuro(raw or ""), iban = iban, blz = blz, konto = konto, raw = html}
end

-- Gesamt-Bestandswert der Uebersichtsseite (Kachel "Bestandswert")
local function fetchOverviewTotal ()
  local html = safeGet(OVERVIEW_URL)
  if html == nil then return nil end
  html = html:gsub("\226\136\146", "-")
  local raw = html:match("Bestandswert%s*</h6>%s*<h5[^>]*>%s*([%-]?%s*[%d%.]+,%d%d)")
  return parseEuro(raw or "")
end

local function ensurePortfolio ()
  if portfolio ~= nil then return portfolio end

  MM.printStatus("WIWIN: Investitionen laden")

  local rows, seen = {}, {}
  collectList("active", rows, seen)
  if INCLUDE_REPAID then collectList("finished", rows, seen) end
  dbg("Investitionen gefunden: " .. #rows)
  if #rows == 0 and DEBUG then
    local html = safeGet(INVEST_LIST) or ""
    print("[investments] " .. html:sub(1, 1500):gsub("%s+", " "))
  end

  local positions = {}
  for _, row in ipairs(rows) do
    MM.printStatus("WIWIN: Investition " .. row.id)
    local html = FETCH_DETAILS and safeGet(INVEST_LIST .. "/" .. row.id) or nil
    local inv = parseInvestment(html, row)
    if inv.amount == nil then
      print("WIWIN: Investition " .. row.id .. " (" .. tostring(inv.name) .. "): kein Wert erkannt -- uebersprungen.")
    elseif inv.amount == 0 and not INCLUDE_REPAID then
      dbg("  Investition " .. row.id .. ": 0,00 -> uebersprungen")
    else
      table.insert(positions, inv)
      dbg(string.format("  %-36s %10.2f EUR  ISIN=%s  %s  [%s]",
          tostring(inv.name), inv.amount, tostring(inv.isin), tostring(inv.contractNo), inv.source))
    end
  end

  local bal = fetchBalance()
  dbg("Guthaben: " .. tostring(bal.cash) .. "  IBAN: " .. tostring(bal.iban))
  if bal.cash == nil and INCLUDE_CASH then
    print("WIWIN: Guthaben des Verrechnungskontos nicht erkannt.")
    if DEBUG then print("[account_balance] " .. tostring(bal.raw):sub(1, 1000):gsub("%s+", " ")) end
  end

  -- Plausibilitaet: Summe der Positionen gegen den Portal-Bestandswert.
  -- Nur eine Warnung -- die Positionen bleiben, wie sie gelesen wurden.
  local total = fetchOverviewTotal()
  if total ~= nil then
    local sum = 0
    for _, inv in ipairs(positions) do
      if inv.listStatus ~= "finished" then sum = sum + inv.amount end
    end
    if math.abs(sum - total) > 0.01 then
      print(string.format("WIWIN: Summe der Positionen (%.2f EUR) weicht vom Bestandswert " ..
        "des Portals (%.2f EUR) ab. Moegliche Ursachen: Detailseite nicht geladen " ..
        "(Wert = Investitionsbetrag), Position nicht erkannt. DEBUG=true fuer Details.", sum, total))
    else
      dbg(string.format("Plausibilitaet OK: Positionen %.2f EUR = Portal-Bestandswert", sum))
    end
  end

  portfolio = {
    positions = positions,
    cash      = bal.cash,
    iban      = bal.iban,
    blz       = bal.blz,
    konto     = bal.konto
  }
  return portfolio
end

-- Positionsname inkl. optionaler Zusaetze
local function positionName (inv)
  local label = inv.name or ("Investition " .. tostring(inv.id))
  if inv.issuer and inv.issuer ~= "" then
    label = label .. " (" .. inv.issuer .. ")"
  end
  if RICH_NAMES then
    local extra = {}
    if inv.instrument and inv.instrument ~= "" then table.insert(extra, inv.instrument) end
    if inv.contractNo and inv.contractNo ~= "" then table.insert(extra, inv.contractNo) end
    if #extra > 0 then label = label .. " · " .. table.concat(extra, " · ") end
  end
  return label
end

-- ---------------------------------------------------------------------------
-- Einsprungspunkte
-- ---------------------------------------------------------------------------

function SupportsBank (protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "WIWIN Crowdinvesting"
end

function InitializeSession (protocol, bankCode, username, reserved, password)
  MM.printStatus("WIWIN: Anmeldung")
  dbg("Login-Weg: invest.wiwin.de (Portagon-Kundenportal)")

  if type(username) ~= "string" or username == ""
     or type(password) ~= "string" or password == "" then
    print("WIWIN: E-Mail oder Passwort fehlt.")
    return LoginFailed
  end

  local loginPage = (request("GET", LOGIN_URL))
  local token = extractCsrf(loginPage)
  if token == nil then
    return "WIWIN-Anmeldeseite: kein CSRF-Token gefunden. Ist invest.wiwin.de erreichbar?"
  end
  dbg("CSRF-Token Laenge: " .. #token)

  -- Feldnamen wie der Browser URL-kodiert (session%5Bemail%5D)
  local function field (k, v)
    return MM.urlencode(k, "UTF-8") .. "=" .. MM.urlencode(v, "UTF-8")
  end
  local body = field("authenticity_token", token) ..
               "&" .. field("session[email]", username) ..
               "&" .. field("session[password]", password) ..
               "&" .. field("commit", "Anmelden")

  local result = (request("POST", LOGIN_URL, body,
                          "application/x-www-form-urlencoded; charset=UTF-8",
                          {["Origin"] = BASE, ["Referer"] = LOGIN_URL}))

  if type(result) == "string" then
    -- Zweiter Faktor (Devise-Two-Factor o.ae.): nicht unterstuetzt, klar melden
    if result:find("otp_attempt", 1, true) or result:find('name="otp"', 1, true)
       or result:find("one_time_password", 1, true) then
      return "WIWIN verlangt einen zweiten Faktor (Einmalcode). Dieser Anmeldeweg " ..
             "wird von der Extension noch nicht unterstuetzt -- bitte melden."
    end
    -- Login-Formular erneut sichtbar -> Zugangsdaten abgelehnt
    if result:find("session%[password%]") then
      local flash = flashMessage(result)
      print("WIWIN: Anmeldung abgelehnt" .. (flash and (": " .. flash) or "") ..
            ". Hinweis: Zugangsdaten von invest.wiwin.de verwenden, nicht von wiwin-invest.de.")
      return LoginFailed
    end
  end

  return nil
end

function ListAccounts (knownAccounts)
  local p = ensurePortfolio()

  local accounts = {}

  local depot = {
    name          = "WIWIN Depot",
    accountNumber = p.konto or DEPOT_NUMBER,
    portfolio     = true,
    type          = AccountTypePortfolio,
    currency      = CURRENCY
  }
  if p.blz then depot.bankCode = p.blz end
  table.insert(accounts, depot)

  if INCLUDE_CASH and SEPARATE_CASH_ACCOUNT then
    local cash = {
      name          = "WIWIN Verrechnungskonto",
      accountNumber = p.iban or CASH_NUMBER,
      portfolio     = false,
      type          = AccountTypeGiro,
      currency      = CURRENCY
    }
    if p.blz  then cash.bankCode = p.blz end
    if p.iban then cash.iban = p.iban end
    table.insert(accounts, cash)
  end

  if #p.positions == 0 and p.cash == nil then
    return "Keine Investitionen und kein Guthaben gefunden. DEBUG=true setzen und Protokoll pruefen."
  end
  return accounts
end

function RefreshAccount (account, since)
  local p = ensurePortfolio()

  -- Separates Cash-Konto
  if SEPARATE_CASH_ACCOUNT and not account.portfolio
     and (account.accountNumber == p.iban or account.accountNumber == CASH_NUMBER) then
    return {balance = (type(p.cash) == "number") and p.cash or 0, transactions = {}}
  end

  -- Depot: eine Position je Investition, mit strukturierten Feldern
  local securities = {}
  for _, inv in ipairs(p.positions) do
    local sec = {
      name     = positionName(inv),
      amount   = inv.amount,
      currency = CURRENCY
    }
    if inv.isin then sec.isin = inv.isin end
    if inv.date then sec.tradeTimestamp = inv.date end
    -- Stueckzahl/Kurs nur setzen, wenn BEIDE bekannt sind (sonst wuerde
    -- MoneyMoney einen Wert aus Kurs*Stueck berechnen, der vom Bestandswert
    -- abweichen koennte).
    if inv.quantity and inv.price then
      sec.quantity      = inv.quantity
      sec.purchasePrice = inv.price
    end
    table.insert(securities, sec)
  end

  -- Guthaben als Position im Depot (sofern nicht als eigenes Konto gefuehrt);
  -- auch negativ, damit der Depotwert dem Portal entspricht.
  if INCLUDE_CASH and not SEPARATE_CASH_ACCOUNT
     and type(p.cash) == "number" and p.cash ~= 0 then
    table.insert(securities, {
      name     = "Verfügbares Guthaben (Verrechnungskonto Baader Bank)",
      amount   = p.cash,
      currency = CURRENCY
    })
  end

  return {securities = securities}
end

function EndSession ()
  pcall(function () request("GET", BASE .. "/investor/logout") end)
  if connection ~= nil then
    pcall(function () connection:close() end)
    connection = nil
  end
  portfolio = nil
  return nil
end

dbg("WIWIN Extension geladen (v1.05)")
