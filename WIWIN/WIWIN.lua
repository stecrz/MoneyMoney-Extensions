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
-- Vertragsnummer) und optional das freie Guthaben des Verrechnungskontos.
-- Nichts ist fest verdrahtet -- Projekte, Betraege, IDs, ISINs, Bankdaten
-- werden aus den Portalseiten gelesen; funktioniert daher auch mit vielen
-- oder andersartigen Positionen.
--
-- FUNKTIONSWEISE
--   1. GET  /investor/login                  -> CSRF-Token (authenticity_token)
--   2. POST /investor/login                  -> Session-Cookie (Rails/Devise)
--   3. GET  /investor/account/investments     \ IDs aller Investitionen
--      GET  /investor/account/overview        / (mehrere Quellen)
--   4. GET  /investor/account/investments/ID -> Detaildaten je Investition
--   5. GET  /investor/account/account_balance.turbo_stream -> Guthaben + IBAN
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
-- Lizenz: MIT. Ohne Gewaehr, keine Verbindung zur WIWIN GmbH oder Portagon.

WebBanking{
  version     = 1.03,
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

-- Freies Guthaben des Verrechnungskontos (Baader Bank) mit abbilden.
local INCLUDE_CASH = true

-- Guthaben als EIGENES Konto statt als Position im Depot fuehren.
local SEPARATE_CASH_ACCOUNT = false

-- Auch vollstaendig zurueckgezahlte / mit 0,00 EUR bewertete Investitionen
-- anzeigen. Standard aus.
local INCLUDE_REPAID = false

-- Zusatzinfos (Finanzinstrument, Vertragsnummer) an den Positionsnamen
-- anhaengen. Die ISIN steht ohnehin im eigenen Feld der Depotposition.
local RICH_NAMES = true

-- Ausfuehrliche Protokollausgaben zur Fehlersuche. Standard aus.
local DEBUG = false

local BASE         = "https://invest.wiwin.de"
local LOGIN_URL    = BASE .. "/investor/login"
local INVEST_LIST  = BASE .. "/investor/account/investments"
local OVERVIEW_URL = BASE .. "/investor/account/overview"
local BALANCE_URL  = BASE .. "/investor/account/account_balance.turbo_stream"

local CURRENCY      = "EUR"
local DEPOT_NUMBER  = "WIWIN-PORTFOLIO"
local CASH_NUMBER   = "WIWIN-CASH"

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

local function request (method, url, body, contentType, headers)
  local content, charset, mimeType, filename, respHeaders =
    conn():request(method, url, body, contentType, headers)

  local hops = 0
  while hops < 10 do
    local loc = headerValue(respHeaders, "location")
    if loc == nil or loc == "" then break end
    if loc:sub(1, 1) == "/" then loc = BASE .. loc end
    hops = hops + 1
    content, charset, mimeType, filename, respHeaders =
      conn():request("GET", loc, nil, nil, headers)
  end

  return content, respHeaders
end

-- ---------------------------------------------------------------------------
-- Parser-Hilfsfunktionen
-- ---------------------------------------------------------------------------

local function parseEuro (s)
  if type(s) ~= "string" then return nil end
  local int, dec = s:match("([%d%.]+),(%d%d)")
  if not int then return nil end
  return tonumber((int:gsub("%.", "")) .. "." .. dec)
end

local function decodeEntities (s)
  if type(s) ~= "string" then return s end
  return (s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
           :gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " "))
end

local function trim (s)
  return (tostring(s or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Ersten Geldbetrag NACH einer Beschriftung finden (Euro-Zeichen optional,
-- darf in eigenem span stehen).
local function moneyAfter (html, label)
  local pat = label:gsub("(%W)", "%%%1") .. ".-([%d%.]+,%d%d)"
  return parseEuro(html:match(pat) or "")
end

-- Wert einer Detailzeile: <strong>LABEL</strong> ... fw-bold> WERT </...
local function detailField (html, label)
  local pat = "<strong>%s*" .. label:gsub("(%W)", "%%%1") ..
              "%s*</strong>.-fw%-bold[^>]*>%s*(.-)%s*</"
  local v = html:match(pat)
  if v == nil then return nil end
  v = v:gsub("<[^>]*>", "")
  v = trim(decodeEntities(v))
  if v == "" then return nil end
  return v
end

-- "08.07.26" / "08.07.2026" -> POSIX ; sonst nil
local function parseDate (s)
  if type(s) ~= "string" then return nil end
  local d, m, y = s:match("(%d%d?)%.(%d%d?)%.(%d%d%d?%d?)")
  if not d then return nil end
  y = tonumber(y); if y < 100 then y = 2000 + y end
  return os.time({year = y, month = tonumber(m), day = tonumber(d), hour = 12})
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
      or html:match('value="([^"]+)"%s+name="authenticity_token"')
      or html:match('name="csrf%-token"%s+content="([^"]+)"')
      or html:match('content="([^"]+)"%s+name="csrf%-token"')
end

-- ---------------------------------------------------------------------------
-- Datenextraktion
-- ---------------------------------------------------------------------------

local function collectInvestmentIds (htmls)
  local ids, seen = {}, {}
  for _, html in ipairs(htmls) do
    if type(html) == "string" then
      for id in html:gmatch("/investor/account/investments/(%d+)") do
        if not seen[id] then
          seen[id] = true
          table.insert(ids, id)
        end
      end
    end
  end
  return ids
end

-- Eine Investitionsdetailseite vollstaendig parsen
local function parseInvestment (html, id)
  if type(html) ~= "string" then return nil end

  local name = html:match("<h3[^>]*>(.-)</h3>")
  name = name and trim(decodeEntities(name)) or ("Investition " .. tostring(id))

  local issuer = html:match("</h3>%s*<p[^>]*>(.-)</p>")
  issuer = issuer and trim(decodeEntities(issuer)) or nil

  local amount = nil
  for _, label in ipairs(VALUE_LABELS) do
    amount = moneyAfter(html, label)
    if amount ~= nil then break end
  end
  if amount == nil then return nil end

  local inv = {
    id         = id,
    name       = name,
    issuer     = issuer,
    amount     = amount,
    isin       = detailField(html, "ISIN"),
    instrument = detailField(html, "Finanzinstrument"),
    contractNo = detailField(html, "Vertragsnummer"),
    status     = detailField(html, "Status"),
    date       = parseDate(detailField(html, "Investitionsdatum"))
  }

  -- Stueckzahl / Stueckpreis, falls die Seite sie zeigt (instrumentabhaengig)
  local qty = detailField(html, "Anzahl") or detailField(html, "Stückzahl")
              or detailField(html, "Stück") or detailField(html, "Anteile")
              or detailField(html, "Stückzahl / Anteile")
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
-- Betrag steht als "0,00 <span class='currency_symbol'>EUR</span>".
local function fetchBalance ()
  local ok, html = pcall(function ()
    return (request("GET", BALANCE_URL, nil, nil, {
      ["Accept"] = "text/vnd.turbo-stream.html, text/html",
      ["X-Requested-With"] = "XMLHttpRequest"
    }))
  end)
  if not ok or type(html) ~= "string" then return {} end

  local raw = html:match('([%d%.]+,%d%d)%s*<span[^>]*currency_symbol')
              or html:match('([%d%.]+,%d%d)%s*<span[^>]*currency')
              or html:match('Verf.-Guthaben.-([%d%.]+,%d%d)')
              or html:match('([%d%.]+,%d%d)')

  local iban, blz, konto = ibanParts(html)
  return {cash = parseEuro(raw or ""), iban = iban, blz = blz, konto = konto, raw = html}
end

local function ensurePortfolio ()
  if portfolio ~= nil then return portfolio end

  MM.printStatus("WIWIN: Investitionen laden")

  local listHtml = (request("GET", INVEST_LIST))
  local overviewHtml = (request("GET", OVERVIEW_URL))
  local ids = collectInvestmentIds({listHtml, overviewHtml})
  dbg("Investitionen gefunden: " .. #ids)
  if #ids == 0 and DEBUG then
    print("[investments] " .. tostring(listHtml):sub(1, 1500):gsub("%s+", " "))
  end

  local positions = {}
  for _, id in ipairs(ids) do
    MM.printStatus("WIWIN: Investition " .. id)
    local html = (request("GET", INVEST_LIST .. "/" .. id))
    local inv = parseInvestment(html, id)
    if inv == nil then
      dbg("  Investition " .. id .. ": kein Wert erkannt")
    elseif inv.amount == 0 and not INCLUDE_REPAID then
      dbg("  Investition " .. id .. ": 0,00 -> uebersprungen")
    else
      table.insert(positions, inv)
      dbg(string.format("  %-36s %10.2f EUR  ISIN=%s  %s",
          inv.name, inv.amount, tostring(inv.isin), tostring(inv.contractNo)))
    end
  end

  local bal = {}
  if INCLUDE_CASH then
    bal = fetchBalance()
    dbg("Guthaben: " .. tostring(bal.cash) .. "  IBAN: " .. tostring(bal.iban))
    if bal.cash == nil and DEBUG then
      print("[account_balance] " .. tostring(bal.raw):sub(1, 1000):gsub("%s+", " "))
    end
  else
    -- Bankdaten trotzdem holen (leicht), fuer Kontonummer/BLZ des Depots
    bal = fetchBalance()
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
  local label = inv.name
  if inv.issuer and inv.issuer ~= "" and inv.issuer ~= inv.name then
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

  local loginPage = (request("GET", LOGIN_URL))
  local token = extractCsrf(loginPage)
  if token == nil then
    return "WIWIN-Anmeldeseite: kein CSRF-Token gefunden. Ist invest.wiwin.de erreichbar?"
  end
  dbg("CSRF-Token Laenge: " .. #token)

  local body = "authenticity_token=" .. MM.urlencode(token, "UTF-8") ..
               "&session[email]=" .. MM.urlencode(username, "UTF-8") ..
               "&session[password]=" .. MM.urlencode(password, "UTF-8") ..
               "&commit=" .. MM.urlencode("Anmelden", "UTF-8")

  local result = (request("POST", LOGIN_URL, body,
                          "application/x-www-form-urlencoded; charset=UTF-8"))

  if type(result) == "string" and result:find('session%[password%]') then
    dbg("Nach Login weiterhin Login-Formular sichtbar -> Zugangsdaten falsch.")
    return LoginFailed
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

  return accounts
end

function RefreshAccount (account, since)
  local p = ensurePortfolio()

  -- Separates Cash-Konto
  if account.accountNumber == (p.iban or CASH_NUMBER)
     and SEPARATE_CASH_ACCOUNT and not account.portfolio then
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
    -- MoneyMoney einen Wert aus Kurs*Stueck berechnen, der von Bestandswert
    -- abweichen koennte).
    if inv.quantity and inv.price then
      sec.quantity      = inv.quantity
      sec.purchasePrice = inv.price
    end
    table.insert(securities, sec)
  end

  -- Cash als Position im Depot (sofern nicht als eigenes Konto gefuehrt)
  if INCLUDE_CASH and not SEPARATE_CASH_ACCOUNT
     and type(p.cash) == "number" and p.cash ~= 0 then
    table.insert(securities, {
      name     = "Verfügbares Guthaben (Verrechnungskonto)",
      amount   = p.cash,
      currency = CURRENCY
    })
  end

  return {securities = securities}
end

function EndSession ()
  if connection ~= nil then
    pcall(function () connection:close() end)
    connection = nil
  end
  portfolio = nil
  return nil
end

dbg("WIWIN Extension geladen (v1.03)")

-- SIGNATURE: MC0CFQCMos5ASUTg2IuBMa1kQeK4hARSqAIUSQJGNHmgDqh8iDQgh+ZXOgWRpeA=
