-- DZ-Banking.lua
--
-- MoneyMoney Web Banking Extension fuer "DZ Banking", das Firmenkundenportal
-- der DZ BANK AG (dzbanking.com). Privatkunden werden von der DZ BANK nicht
-- ueber dieses Portal betreut (DZ PRIVATBANK ist ein anderes System).
--
-- Legt fuer jedes Konto der Finanzuebersicht ein eigenes MoneyMoney-Konto an:
--   Kontokorrent  -> Girokonto mit IBAN, Inhaber (Unternehmen), allen Umsaetzen
--                    (Gegen-IBAN, Name, Verwendungszweck, Buchungstext)
--   Tagesgeld /   -> Sparkonto mit Saldo
--   Termingeld
-- Konditionen (Zinssaetze Haben/Soll/Ueberziehung mit Referenzzins, KK-Limit,
-- naechste Abrechnung, Laufzeitbeginn, Tagesgeldzins) werden bei jedem Abruf
-- ins Protokoll geschrieben und -- je nach CONDITIONS_MODE -- in MoneyMoney
-- sichtbar gemacht. Nichts ist fest verdrahtet: Konten, Unternehmen, Waehrungen
-- kommen aus der Portal-API.
--
-- FUNKTIONSWEISE (reine JSON-API, kein HTML-Scraping)
--   1. GET  dzbanking.com -> Redirect-Kette zum Auth-Frontend (Cookies)
--   2. POST /services_auth/auth-backend/api/init-ui -> RSA-Schluessel, Nonce
--   3. POST /services_auth/auth-backend/api/authentication/login
--        Body = JWE (RSA-OAEP-512 + A256GCM) ueber {netkey, pin, nonce}
--   4. POST .../consent/execution -> OAuth-Code -> Redirect-Kette ->
--      POST /services_cloud/portal/portal-oauth/oauth/token -> Session-Cookie
--   5. GET  .../FinanzstatusApi/konten/alleunternehmen -> Kontenliste
--   6. GET  .../konto/kontokorrent/{id}            -> Details + Zinssaetze
--      GET  .../konto/kontokorrent/{id}/umsaetze   -> Umsaetze (paginiert)
--      GET  .../konto/termintagesgelder/{id}       -> Tagesgeld-Details
--   Die Portal-Session laeuft nach ~90 s ab und wird vor jedem Kontoabruf per
--   Refresh-Grant verlaengert.
--   7. Erstimport: Umsaetze aelter als 90 Tage gibt das Portal nur nach einer
--      SecureGo-Freigabe heraus (PSD2). Beim ersten Login je Kontokorrentkonto:
--      GET  .../umsaetze/erfragetanpruefung -> tanprozessId
--      POST .../TanKomponenteApi/liefereTanVerfahren -> nur SECUREGO_PLUS wird
--           unterstuetzt; andere Verfahren -> Import mit Hinweis uebersprungen
--      POST .../TanKomponenteApi/direktfreigabe/authentication -> Push in die App
--      GET  .../direktfreigabe/authentication/{id} (Polling, MoneyMoney-Wartedialog)
--      GET  .../umsaetze?tanProzessId=... -> bis zu 18 Monate Historie
--      Wird die Freigabe nicht erteilt, fragt ein Dialog, ob ohne Altdaten
--      fortgefahren werden soll. Erledigte Importe merkt sich LocalStorage.
--
-- ZWEITER FAKTOR: Der Lesezugriff verlangt derzeit keinen. Fordert die Bank
-- kuenftig einen an, meldet die Extension den Schritt namentlich.
--
-- INSTALLATION
--   Signierte Version: einfach in den Extensions-Ordner legen.
--   Unsigniert (Eigenbau): MoneyMoney > Einstellungen > Extensions >
--     "Digitale Signatur von Extensions ueberpruefen" deaktivieren.
--   Ordner: MoneyMoney > Hilfe > Datenbank im Finder zeigen > "Extensions".
--   Danach: Konto hinzufuegen > Andere > DZ Banking
--   Benutzername = VR-NetKey (oder Alias), Passwort = PIN.
--
-- Fehlersuche: DEBUG unten auf true setzen, dann Fenster > Protokollfenster.
-- Lizenz: CC0 1.0 (Public-Domain-Freigabe). Soweit rechtlich moeglich, wird
-- auf alle Urheber- und verwandten Rechte an dieser Software verzichtet. Sie
-- wird OHNE JEDE GEWAEHR bereitgestellt. Lizenztext:
-- https://creativecommons.org/publicdomain/zero/1.0/
-- Keine Verbindung zur DZ BANK AG, Atruvia AG oder MRH applications.

WebBanking{
  version     = 1.05,
  url         = "https://dzbanking.com/",
  services    = {"DZ Banking"},
  description = "Firmenkundenportal DZ Banking der DZ BANK AG (dzbanking.com): " ..
                "Kontokorrent mit Umsaetzen, Tagesgeld/Termingeld, Konditionen. " ..
                "Benutzername = VR-NetKey oder Alias, Passwort = PIN."
}

-- ---------------------------------------------------------------------------
-- Konfiguration
-- ---------------------------------------------------------------------------

-- Wie Konditionen (Zinssaetze, KK-Limit, naechste Abrechnung, Laufzeit) in
-- MoneyMoney sichtbar gemacht werden. MoneyMoney hat kein frei befuellbares,
-- aktualisierbares Textfeld fuer Konten, daher drei Wege:
--   "pending" : eine vorgemerkte 0-Euro-Buchung "Konditionen" je Konto, die
--               MoneyMoney bei jedem Abruf ersetzt -- immer aktuell, nie in
--               der Historie, ohne Einfluss auf den Saldo. (Standard)
--   "name"    : Konditionen im Kontonamen -- nur bei der Kontoanlage, danach
--               nicht mehr aktualisiert.
--   "off"     : nur im Protokoll.
local CONDITIONS_MODE = "pending"

-- Tages-/Termingeld hat im Portal keine eigenen Umsaetze. true: Kapital-
-- bewegungen (Anlage/Rueckzahlung) werden aus den Gegenbuchungen des
-- Kontokorrentkontos abgeleitet und als Umsaetze des Tagesgeldkontos gefuehrt
-- (Zinsen fliessen aufs Kontokorrent und bleiben dort).
local MIRROR_SAVINGS_BOOKINGS = true

-- Umsaetze, die aelter als 90 Tage sind, gibt das Portal nur nach einer
-- SecureGo-Freigabe heraus (PSD2). Im laufenden Betrieb reicht die Extension
-- daher hoechstens so viele Tage zurueck.
local MAX_DAYS = 89

-- Einmaliger Erstimport der Umsatzhistorie je Kontokorrentkonto mit SecureGo-
-- Freigabe: Beim ersten Login nach der Einrichtung fragt MoneyMoney die
-- Freigabe in der App ab (Wartedialog), danach werden so viele Tage geladen.
-- Das Portal erlaubt hoechstens etwa 18 Monate. 0 = kein Erstimport.
local HISTORY_DAYS = 540

-- true: Erstimport beim naechsten Login erneut durchfuehren (danach wieder
-- auf false setzen). Nuetzlich, wenn die Freigabe abgelehnt oder abgebrochen
-- wurde und die Historie doch geladen werden soll.
local HISTORY_RESET = false

-- Umsaetze je Seite (Portal-Standard 300)
local PAGE_SIZE = 300

-- Ausfuehrliche Protokollausgaben zur Fehlersuche. Zugangsdaten werden nie
-- protokolliert, auch nicht bei DEBUG.
local DEBUG = false

local BASE        = "https://dzbanking.com"
local PORTAL      = BASE .. "/services_cloud/portal"
local AUTH_API    = BASE .. "/services_auth/auth-backend/api"
local OAUTH       = PORTAL .. "/portal-oauth"
local TOKEN_URL   = OAUTH .. "/oauth/token"
local LOGIN_REDIR = OAUTH .. "/login"
local PORTAL_LOGIN = PORTAL .. "/login"
local FINANZ_API  = PORTAL .. "/proxy-gateway/serviceproxy/grokfin-uebersicht-service-v1/rest/" ..
                    "de.fiduciagad.grokfin.uebersicht.api.v1.FinanzstatusApi"
local TAN_API     = PORTAL .. "/proxy-gateway/serviceproxy/identitaet-tan-komponente-v1/rest/" ..
                    "de.bankenit.identitaet.tan.komponente.v1.TanKomponenteApi"
local POLL_SECONDS = 3   -- Abstand der Statusabfragen waehrend der Freigabe (wie das Portal)
local TOKEN_TTL   = 60   -- Sekunden, nach denen die Session verlaengert wird

-- Bekannte Referenzzins-Codes des Portals (Anzeige); unbekannte bleiben roh
local REFERENCE_RATES = {
  ["01DEURESTM"] = "€STR"
}

-- ---------------------------------------------------------------------------
-- Zustand
-- ---------------------------------------------------------------------------

local connection   = nil
local accountsList = nil   -- Kontenliste aus der API (Rohdaten)
local byNumber     = {}    -- accountNumber -> Kontoeintrag
local detailsCache = {}    -- kontoID -> Detaildaten
local lastToken    = 0     -- Zeitpunkt der letzten Token-Ausgabe/-Verlaengerung
local historyCache = {}    -- kontoID -> Umsaetze aus dem Erstimport (diese Sitzung)
local importState  = nil   -- laufender Erstimport: {queue=, current=}

local function dbg (...) if DEBUG then print(...) end end

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
  while hops < 12 do
    local loc = headerValue(respHeaders, "location")
    if loc == nil or loc == "" then break end
    hops = hops + 1
    current = resolveLocation(current, loc)
    content, charset, mimeType, filename, respHeaders =
      conn():request("GET", current, nil, nil, headers)
  end
  return content, respHeaders
end

local JSON_HEADERS = {
  ["Accept"]          = "application/json, text/plain, */*",
  ["X-VP-App-Locale"] = "de-DE"
}

local function parseJSON (content)
  if type(content) ~= "string" or content == "" then return nil end
  local ok, data = pcall(function () return JSON(content):dictionary() end)
  if ok then return data end
  return nil
end

local function getJSON (url)
  local content = (request("GET", url, nil, nil, JSON_HEADERS))
  local data = parseJSON(content)
  if data == nil then dbg("Keine JSON-Antwort von " .. url:sub(-80)) end
  return data, content
end

local function postJSON (url, body, contentType, extraHeaders)
  local headers = {}
  for k, v in pairs(JSON_HEADERS) do headers[k] = v end
  for k, v in pairs(extraHeaders or {}) do headers[k] = v end
  local content = (request("POST", url, body or "", contentType or "application/json", headers))
  return parseJSON(content), content
end

-- ---------------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------------

-- "2026-11-02" -> POSIX (12:00 lokal) ; sonst nil
local function parseDate (s)
  if type(s) ~= "string" then return nil end
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then return nil end
  local ok, t = pcall(os.time, {year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12})
  if ok then return t end
  return nil
end

local function isoDate (t)
  return os.date("%Y-%m-%d", math.floor(tonumber(t) or os.time()))
end

local function fmtDate (s)
  local y, m, d = tostring(s or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if y then return d .. "." .. m .. "." .. y end
  return tostring(s)
end

-- Zahl mit deutschem Dezimalkomma, feste Nachkommastellen
local function fmtNum (n, decimals)
  if type(n) ~= "number" then return "-" end
  local s = string.format("%." .. (decimals or 2) .. "f", n)
  local int, frac = s:match("^(%-?%d+)%.?(%d*)$")
  int = int:reverse():gsub("(%d%d%d)", "%1."):reverse():gsub("^%.", ""):gsub("^%-%.", "-")
  if frac ~= "" then return int .. "," .. frac end
  return int
end

local function fmtAmount (n, currency)
  return fmtNum(n, 2) .. " " .. tostring(currency or "EUR")
end

-- Zinssatz: 2 bis 3 Nachkommastellen ("2,40 %", "7,445 %")
local function fmtRate (n)
  local s = fmtNum(n, 3)
  if s:sub(-1) == "0" then s = s:sub(1, -2) end
  return s .. " %"
end

local function amountOf (v)
  if type(v) == "table" then v = v["betrag"] end
  if type(v) == "number" then return v end
  return nil
end

local function currencyOf (v, default)
  if type(v) == "table" and type(v["waehrung"]) == "string" and v["waehrung"] ~= "" then
    return v["waehrung"]
  end
  return default or "EUR"
end

local function bankCodeFromIban (iban)
  if type(iban) == "string" and iban:match("^DE%d%d%d%d%d%d%d%d%d%d") then
    return iban:sub(5, 12)
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Anmeldung
-- ---------------------------------------------------------------------------

-- JWE (Compact Serialization) nach RFC 7516:
--   alg RSA-OAEP-512 (RSAES-OAEP, SHA-512 fuer Hash und MGF1)
--   enc A256GCM      (AES-256-GCM, 96-Bit-IV, 128-Bit-Tag, AAD = Header)
local function buildJWE (jwk, plaintext)
  local n = MM.base64decode(jwk["n"])
  local e = MM.base64decode(jwk["e"])
  if n == nil or e == nil then return nil, "Oeffentlicher Schluessel unlesbar." end

  local header = '{"alg":"RSA-OAEP-512","enc":"A256GCM","kid":"' .. tostring(jwk["kid"] or "") .. '"}'
  local protected = MM.base64urlencode(header)

  local cek = MM.random(32)
  local iv  = MM.random(12)
  local encryptedKey = MM.rsaEncrypt({n = n, e = e}, cek, "pkcs1-oaep sha512")
  if encryptedKey == nil then return nil, "RSA-Verschluesselung fehlgeschlagen." end

  local ciphertext, tag = MM.aes256encrypt(cek, iv, plaintext, "aes256 gcm", protected)
  if ciphertext == nil or tag == nil then return nil, "AES-GCM-Verschluesselung fehlgeschlagen." end

  return protected .. "." .. MM.base64urlencode(encryptedKey) .. "." ..
         MM.base64urlencode(iv) .. "." .. MM.base64urlencode(ciphertext) .. "." ..
         MM.base64urlencode(tag)
end

-- Erste Aktion eines bestimmten Typs aus einem Post-Auth-Schritt
local function findAction (step, stepType)
  if type(step) ~= "table" then return nil end
  for _, a in ipairs(step["actions"] or {}) do
    if a["stepType"] == stepType then return a end
  end
  return nil
end

local function actionTypes (step)
  local out = {}
  if type(step) == "table" then
    for _, a in ipairs(step["actions"] or {}) do table.insert(out, tostring(a["stepType"])) end
  end
  return table.concat(out, ", ")
end

local function describeStep (step)
  if type(step) ~= "table" then return "?" end
  return tostring(step["stepType"] or step["type"] or step["name"] or actionTypes(step))
end

-- Session-Token holen (authorization_code) bzw. verlaengern (refresh_token)
local function requestToken (body)
  local data = postJSON(TOKEN_URL, body, "application/x-www-form-urlencoded",
                        {["X-Portal-Locked-Request"] = "true"})
  if type(data) == "table" and data["token_type"] ~= nil then
    lastToken = MM.time()
    return true
  end
  return false
end

local function keepAlive ()
  if MM.time() - lastToken < TOKEN_TTL then return end
  if requestToken("grant_type=refresh_token&refresh_token=0&extendSessionDuration=PT299s") then
    dbg("Session verlaengert")
  else
    print("DZ Banking: Session konnte nicht verlaengert werden -- Abruf wird trotzdem versucht.")
  end
end

local function login (username, password)
  -- 1. Portal aufrufen und OAuth-Kette bis zum Auth-Frontend durchlaufen
  request("GET", BASE .. "/")
  request("GET", OAUTH .. "/oauth/authorize?redirect_uri=" .. MM.urlencode(PORTAL_LOGIN, "UTF-8") ..
                 "&response_type=code&state=" .. MM.uuid() .. "&client_id=webClient")

  -- 2. Schluessel, Nonce und State vom Auth-Backend
  local init = postJSON(AUTH_API .. "/init-ui?client_id=online-banking&redirect_uri=" ..
                        MM.urlencode(LOGIN_REDIR, "UTF-8"), "", "application/json")
  if type(init) ~= "table" then
    return "Anmeldedienst der DZ BANK antwortet nicht (init-ui)."
  end
  local locked = tonumber(init["loginLockedSeconds"]) or 0
  if locked > 0 then
    return "Der Zugang ist noch " .. locked .. " Sekunden gesperrt (zu viele Fehlversuche)."
  end
  local jwk   = init["pinEncryptionPublicKey"]
  local nonce = init["pinEncryptionNonce"]
  if type(jwk) ~= "table" or jwk["n"] == nil or nonce == nil then
    return "Anmeldedienst liefert keinen Verschluesselungsschluessel."
  end
  dbg("Bank: " .. tostring(init["bankName"]) .. ", Schluessel-ID: " .. tostring(jwk["kid"]))

  -- 3. Zugangsdaten verschluesselt senden
  local payload = JSON():set({netkey = username, pin = password, nonce = nonce}):json()
  local jwe, err = buildJWE(jwk, payload)
  if jwe == nil then return "Verschluesselung der Zugangsdaten fehlgeschlagen: " .. tostring(err) end

  local auth, raw = postJSON(AUTH_API .. "/authentication/login", jwe, "application/jose")
  if type(auth) ~= "table" then
    print("DZ Banking: unerwartete Antwort auf die Anmeldung: " .. tostring(raw):sub(1, 300))
    return LoginFailed
  end

  if auth["authenticationProcessResponse"] == nil and auth["code"] ~= nil then
    -- HTTP 401 {"code":"INVALID_CREDENTIALS", ...}
    print("DZ Banking: Anmeldung abgelehnt (" .. tostring(auth["code"]) ..
          "). Benutzername = VR-NetKey/Alias, Passwort = PIN.")
    return LoginFailed
  end
  local apr = auth["authenticationProcessResponse"] or {}
  if apr["authenticationProcessCompleted"] ~= true then
    local nxt = apr["nextAuthenticationProcessStep"]
    if nxt ~= nil then
      return "Die DZ BANK verlangt einen weiteren Anmeldeschritt (" .. describeStep(nxt) ..
             "), den diese Extension nicht unterstuetzt -- bitte melden."
    end
    local res = apr["resultOfCurrentAuthenticationProcessStep"]
    print("DZ Banking: Anmeldung abgelehnt" ..
          (type(res) == "table" and (": " .. tostring(res["status"] or res["message"] or "")) or "") ..
          ". Benutzername = VR-NetKey/Alias, Passwort = PIN.")
    return LoginFailed
  end

  -- 4. Post-Auth-Schritte (Consent) bis der OAuth-Code vorliegt
  local parameter = nil
  for _ = 1, 5 do
    local ppr = auth["postAuthenticationProcessResponse"] or {}
    local result = ppr["resultOfCurrentPostAuthenticationProcessStep"]
    if type(result) == "table" and type(result["parameter"]) == "string" then
      parameter = result["parameter"]
      break
    end
    local nxt = ppr["nextPostAuthenticationProcessStep"]
    if nxt == nil then break end
    local consent = findAction(nxt, "PROCESS_CONSENT")
    if consent == nil then
      return "Die DZ BANK verlangt nach der Anmeldung einen Schritt (" .. actionTypes(nxt) ..
             "), den diese Extension nicht unterstuetzt -- bitte melden."
    end
    dbg("Post-Auth-Schritt: PROCESS_CONSENT")
    auth = postJSON(consent["urlOfResource"], '{"useBrowserDetection":false}', "application/json")
    if type(auth) ~= "table" then return "Anmeldedienst antwortet nicht (consent)." end
  end
  if parameter == nil or not parameter:find("code=", 1, true) then
    return "Anmeldung ohne Autorisierungscode beendet."
  end

  -- 5. Redirect-Kette ins Portal; der Portal-Code steht in der End-URL
  request("GET", LOGIN_REDIR .. "?" .. parameter)
  local finalUrl = ""
  pcall(function () finalUrl = tostring(conn():getBaseURL() or "") end)
  local code = finalUrl:match("[?&]code=([^&#]+)")
  if code == nil then
    return "Portal-Anmeldung: kein Autorisierungscode in der Ziel-URL (" ..
           finalUrl:sub(1, 80) .. "). Bitte mit DEBUG=true melden."
  end

  -- 6. Session-Token (als Cookie) gegen den Code eintauschen
  if not requestToken("code=" .. MM.urlencode(code, "UTF-8") ..
                      "&grant_type=authorization_code&redirect_uri=" ..
                      MM.urlencode(PORTAL_LOGIN, "UTF-8")) then
    return "Portal-Anmeldung: Session-Token wurde nicht ausgestellt."
  end

  local info = getJSON(OAUTH .. "/userinfo")
  if type(info) == "table" and info["user_name"] then
    dbg("Angemeldet als " .. tostring(info["user_name"]))
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Datenabruf
-- ---------------------------------------------------------------------------

local function ensureAccounts ()
  if accountsList ~= nil then return accountsList end
  MM.printStatus("Finanzuebersicht laden")
  keepAlive()
  local data, raw = getJSON(FINANZ_API .. "/konten/alleunternehmen?forciereAktuelleDaten=false")
  if type(data) ~= "table" then
    error("Finanzuebersicht nicht lesbar: " .. tostring(raw):sub(1, 200))
  end
  accountsList = data
  byNumber = {}
  for _, k in ipairs(accountsList) do
    local nr = k["ibanOrVertragID"] or k["kontoID"]
    if nr then byNumber[tostring(nr)] = k end
  end
  dbg("Konten in der Finanzuebersicht: " .. #accountsList)
  return accountsList
end

local function kontokorrentDetails (kontoID)
  if detailsCache[kontoID] == nil then
    local d = getJSON(FINANZ_API .. "/konto/kontokorrent/" .. MM.urlencode(kontoID, "UTF-8"))
    detailsCache[kontoID] = (type(d) == "table") and d or false
  end
  return detailsCache[kontoID] or nil
end

local function tagesgeldDetails (vertragsnummer)
  if detailsCache[vertragsnummer] == nil then
    local d = getJSON(FINANZ_API .. "/konto/termintagesgelder/" .. MM.urlencode(vertragsnummer, "UTF-8"))
    detailsCache[vertragsnummer] = (type(d) == "table") and d or false
  end
  return detailsCache[vertragsnummer] or nil
end

local function isSavings (kontoart)
  local k = tostring(kontoart or ""):upper()
  return k:find("TAGESGELD", 1, true) ~= nil or k:find("TERMINGELD", 1, true) ~= nil
     or k:find("FESTGELD", 1, true) ~= nil or k:find("SPAR", 1, true) ~= nil
end

-- Konditionen eines Kontokorrentkontos als Text -- Wichtigstes zuerst:
-- Sollzins, Habenzins, Limit, Ueberziehung, Abrechnung, Referenzzins-Details.
local function kontokorrentConditions (det)
  if type(det) ~= "table" then return nil end
  local kd = det["kontodetails"] or {}
  local rates, refs = {}, {}
  for _, z in ipairs(det["zinssaetze"] or {}) do
    local typ = tostring(z["konditionstyp"] or ""):upper()
    rates[typ] = z
    local ref = z["referenzzins"]
    if type(ref) == "string" and ref ~= "" then
      table.insert(refs, string.format("%s = %s %s + %s%s",
        typ:sub(1, 1) .. typ:sub(2):lower(),
        REFERENCE_RATES[ref] or ref, fmtRate(z["zinssatzReferenzzins"]),
        fmtRate(z["abweichungReferenzzins"]),
        z["gueltigAb"] and (" seit " .. fmtDate(z["gueltigAb"])) or ""))
    end
  end
  local parts = {}
  if rates["SOLL"]  then table.insert(parts, "Soll "  .. fmtRate(rates["SOLL"]["zinssatz"])) end
  if rates["HABEN"] then table.insert(parts, "Haben " .. fmtRate(rates["HABEN"]["zinssatz"])) end
  local limit = amountOf(kd["kklimit"])
  if limit ~= nil then table.insert(parts, "Limit " .. fmtAmount(limit, kd["kontowaehrung"])) end
  if rates["UEBERZIEHUNG"] then
    table.insert(parts, "Überziehung " .. fmtRate(rates["UEBERZIEHUNG"]["zinssatz"]))
  end
  for typ, z in pairs(rates) do
    if typ ~= "SOLL" and typ ~= "HABEN" and typ ~= "UEBERZIEHUNG" then
      table.insert(parts, typ:sub(1, 1) .. typ:sub(2):lower() .. " " .. fmtRate(z["zinssatz"]))
    end
  end
  if kd["naechsteKontoabrechnung"] then
    table.insert(parts, "Abrechnung " .. fmtDate(kd["naechsteKontoabrechnung"]))
  end
  for _, r in ipairs(refs) do table.insert(parts, r) end
  if #parts == 0 then return nil end
  return table.concat(parts, " · ")
end

-- Konditionen eines Tages-/Termingeldes als Text: Zins, Betrag, Laufzeit
local function tagesgeldConditions (det)
  if type(det) ~= "table" then return nil end
  local parts = {}
  if det["zinssatz"] ~= nil then table.insert(parts, fmtRate(det["zinssatz"]) .. " p.a.") end
  if det["betrag"] ~= nil then table.insert(parts, fmtAmount(det["betrag"], det["waehrung"]) .. " angelegt") end
  if det["laufzeitbeginn"] then table.insert(parts, "seit " .. fmtDate(det["laufzeitbeginn"])) end
  if det["laufzeitende"] then table.insert(parts, "bis " .. fmtDate(det["laufzeitende"])) end
  if det["faelligkeit"] then table.insert(parts, "fällig " .. fmtDate(det["faelligkeit"])) end
  if #parts == 0 then return nil end
  return table.concat(parts, " · ")
end

-- Vorgemerkte 0-Euro-Buchung mit den Konditionen (CONDITIONS_MODE = "pending")
local function conditionsTransaction (text, currency)
  return {
    name        = "Konditionen",
    amount      = 0,
    currency    = currency,
    bookingDate = math.floor(os.time()),
    purpose     = text,
    bookingText = "Information der Extension, kein Umsatz",
    booked      = false
  }
end

-- Umsatzseiten eines Kontokorrentkontos fuer einen Zeitraum laden.
-- auth = {tanProzessId=, tanToken=} nach einer SecureGo-Freigabe (optional).
-- Liefert (Liste, ok, letzter tanToken).
local function loadPages (kontoID, from, to, currency, auth)
  local out, total, token = {}, nil, auth and auth.tanToken or nil
  for page = 1, 100 do
    keepAlive()
    local url = string.format("%s/konto/kontokorrent/%s/umsaetze?pagenumber=%d&pagesize=%d" ..
                              "&zeitraumvon=%s&zeitraumbis=%s&nurAZV=false",
                              FINANZ_API, MM.urlencode(kontoID, "UTF-8"), page, PAGE_SIZE,
                              isoDate(from), isoDate(to))
    if auth and auth.tanProzessId then url = url .. "&tanProzessId=" .. MM.urlencode(auth.tanProzessId, "UTF-8") end
    if token then url = url .. "&tanToken=" .. MM.urlencode(token, "UTF-8") end
    local data = getJSON(url)
    if type(data) ~= "table" or type(data["umsaetze"]) ~= "table" then
      return out, false, token
    end
    if type(data["tanToken"]) == "string" and data["tanToken"] ~= "" then token = data["tanToken"] end
    total = tonumber(data["gesamtAnzahl"]) or total
    for _, u in ipairs(data["umsaetze"]) do
      local amount = amountOf(u["betrag"])
      if amount ~= nil then
        local purpose = u["verwendungszweck"]
        if purpose == nil or purpose == "" then purpose = u["buchungstext"] end
        table.insert(out, {
          name          = u["empfaengerAuftraggeber"] or u["buchungstext"],
          accountNumber = u["iban"],
          amount        = amount,
          currency      = currencyOf(u["betrag"], currency),
          bookingDate   = parseDate(u["buchungstag"]) or to,
          valueDate     = parseDate(u["wertstellungstag"]),
          purpose       = purpose,
          bookingText   = u["buchungstext"],
          booked        = true
        })
      end
    end
    dbg(string.format("Umsaetze %s..%s Seite %d: %d (gesamt %s)", isoDate(from), isoDate(to),
        page, #data["umsaetze"], tostring(total)))
    if #data["umsaetze"] == 0 or #data["umsaetze"] < PAGE_SIZE
       or (total ~= nil and #out >= total) then
      break
    end
  end
  return out, true, token
end

-- Umsaetze eines Kontokorrentkontos (laufender Betrieb, max. MAX_DAYS zurueck;
-- gecacht je Konto und Startdatum, damit Spiegelbuchungen keinen zweiten Abruf
-- ausloesen). Liegt ein Erstimport dieser Sitzung vor, wird er verwendet.
local txCache = {}

local function fetchTransactions (kontoID, since, currency)
  if historyCache[kontoID] then return historyCache[kontoID] end

  local today = math.floor(os.time())
  local from  = since
  if type(from) ~= "number" or from <= 0 then from = 0 end
  from = math.floor(from)
  local limit = today - MAX_DAYS * 86400
  if from < limit then
    if since ~= nil and since > 0 then
      dbg("Umsaetze aelter als " .. MAX_DAYS .. " Tage verlangen eine SecureGo-Freigabe -- " ..
          "Abruf ab " .. isoDate(limit))
    end
    from = limit
  end
  if from > today then from = today - 86400 end

  local cacheKey = kontoID .. "|" .. isoDate(from)
  if txCache[cacheKey] then return txCache[cacheKey] end

  -- Rueckfall auf kuerzere Zeitraeume, falls das Portal den Abruf ablehnt
  local windows = {from, today - 60 * 86400, today - 30 * 86400}
  local out = {}
  for wi, start in ipairs(windows) do
    if wi == 1 or start > from then
      local list, ok = loadPages(kontoID, start, today, currency, nil)
      if ok then txCache[cacheKey] = list; return list end
      out = list
      print("DZ Banking: Umsatzabruf ab " .. isoDate(start) .. " abgelehnt" ..
            (wi < #windows and " -- kuerzerer Zeitraum wird versucht." or "."))
    end
  end
  txCache[cacheKey] = out
  return out
end

-- ---------------------------------------------------------------------------
-- Erstimport der Historie mit SecureGo-Freigabe
-- ---------------------------------------------------------------------------

local function historyMarks ()
  if type(LocalStorage) ~= "table" then return {} end
  if type(LocalStorage["historyImported"]) ~= "table" then LocalStorage["historyImported"] = {} end
  return LocalStorage["historyImported"]
end

-- tanToken fuer die TAN-Pruefung: das Portal haengt immer den zuletzt
-- erhaltenen Token an; der erste stammt aus einem normalen Umsatzabruf.
local function seedTanToken (kontoID)
  local today = math.floor(os.time())
  local url = string.format("%s/konto/kontokorrent/%s/umsaetze?pagenumber=1&pagesize=1" ..
                            "&zeitraumvon=%s&zeitraumbis=%s&nurAZV=false",
                            FINANZ_API, MM.urlencode(kontoID, "UTF-8"),
                            isoDate(today - 30 * 86400), isoDate(today))
  local data = getJSON(url)
  if type(data) == "table" and type(data["tanToken"]) == "string" then return data["tanToken"] end
  return nil
end

-- Konten, fuer die ein Erstimport aussteht (Kontokorrent mit Umsatzrecht)
local function pendingHistoryImports ()
  local queue = {}
  if HISTORY_DAYS <= 0 then return queue end
  local marks = historyMarks()
  for _, k in ipairs(ensureAccounts()) do
    if not isSavings(k["kontoart"]) then
      local kontoID = k["kontoID"] or k["ibanOrVertragID"]
      local det = kontokorrentDetails(kontoID)
      local allowed = not (type(det) == "table" and (det["kontodetails"] or {})["darfUmsaetzeSehen"] == false)
      if allowed and (HISTORY_RESET or marks[kontoID] == nil) then
        table.insert(queue, {kontoID = kontoID, nr = tostring(k["ibanOrVertragID"] or kontoID),
                             currency = k["waehrung"] or "EUR"})
      end
    end
  end
  return queue
end

-- Naechstes Konto der Warteschlange anstossen.
-- Liefert nil (alles erledigt), ein Dialog-Table (Freigabe laeuft) oder Fehlertext.
local function startNextHistoryImport ()
  local today = math.floor(os.time())
  while importState ~= nil and #importState.queue > 0 do
    local job = table.remove(importState.queue, 1)
    job.from, job.to = today - HISTORY_DAYS * 86400, today
    keepAlive()
    MM.printStatus("Historie " .. job.nr)
    job.tanToken = seedTanToken(job.kontoID)

    local url = string.format("%s/konto/kontokorrent/%s/umsaetze/erfragetanpruefung?pagenumber=1" ..
                              "&pagesize=%d&sprache=de-DE&zeitraumvon=%s&zeitraumbis=%s&nurAZV=false",
                              FINANZ_API, MM.urlencode(job.kontoID, "UTF-8"), PAGE_SIZE,
                              isoDate(job.from), isoDate(job.to))
    if job.tanToken then url = url .. "&tanToken=" .. MM.urlencode(job.tanToken, "UTF-8") end
    local check = getJSON(url)
    if type(check) ~= "table" then
      print("DZ Banking " .. job.nr .. ": TAN-Pruefung nicht moeglich -- Erstimport uebersprungen.")
    elseif check["pruefungNotwendig"] ~= true then
      -- Keine Freigabe noetig: direkt laden
      local list, ok = loadPages(job.kontoID, job.from, job.to, job.currency, {tanToken = job.tanToken})
      if ok then
        historyCache[job.kontoID] = list
        historyMarks()[job.kontoID] = isoDate(today)
        print("DZ Banking " .. job.nr .. ": Historie ohne Freigabe geladen (" .. #list .. " Umsaetze).")
      end
    else
      job.tanProzessId = check["tanprozessId"]
      -- Verfuegbare TAN-Verfahren pruefen (das Portal ruft dies ebenfalls auf)
      local verfahren = postJSON(TAN_API .. "/liefereTanVerfahren",
                                 '{"tanProzessId":"' .. job.tanProzessId .. '"}', "application/json")
      local secureGo = false
      if type(verfahren) == "table" then
        for _, v in ipairs(verfahren["tanVerfahren"] or {}) do
          if tostring(v["typ"]):find("SECUREGO", 1, true) then secureGo = true end
        end
      end
      if not secureGo then
        print("DZ Banking " .. job.nr .. ": kein SecureGo-Verfahren verfuegbar -- Erstimport uebersprungen.")
      else
        local start = postJSON(TAN_API .. "/direktfreigabe/authentication",
                               '{"tanProzessId":"' .. job.tanProzessId .. '","sprachschluessel":"de-DE"}',
                               "application/json")
        if type(start) ~= "table" or start["status"] == nil then
          print("DZ Banking " .. job.nr .. ": Freigabe konnte nicht gestartet werden -- Erstimport uebersprungen.")
        else
          importState.current = job
          dbg("Freigabe gestartet, Status " .. tostring(start["status"]))
          return {
            title     = "DZ Banking: Umsatzhistorie laden",
            challenge = "Bitte die Abfrage der Umsaetze der letzten " .. math.floor(HISTORY_DAYS / 30) ..
                        " Monate fuer Konto ..." .. job.nr:sub(-4) .. " in der App SecureGo plus freigeben.",
            poll      = true
          }
        end
      end
    end
  end
  importState = nil
  return nil
end

-- Statusabfrage waehrend des Wartedialogs
-- Nach gescheiterter Freigabe: Nutzer fragen, ob die Einrichtung ohne Altdaten
-- fortgesetzt werden soll (ja) oder beim naechsten Mal erneut gefragt wird (nein)
local function askContinueWithoutHistory (job, reason)
  importState.current = nil
  importState.ask = job
  return {
    title     = "DZ Banking: Umsatzhistorie",
    challenge = reason .. " Ohne Freigabe stehen nur die Umsaetze der letzten 90 Tage zur " ..
                "Verfuegung; der Saldo ist davon unabhaengig. Trotzdem fortfahren? " ..
                "(\"ja\" = ohne Altdaten weiter, nicht erneut fragen; \"nein\" = abbrechen, " ..
                "beim naechsten Aktualisieren erneut anfragen)",
    label     = "Ohne Altdaten fortfahren? (ja/nein)"
  }
end

local function isYes (s)
  s = tostring(s or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  return s == "ja" or s == "j" or s == "yes" or s == "y" or s == "ok" or s == "1"
end

local function pollHistoryImport (credentials)
  local job = importState and importState.current
  if job == nil then importState = nil; return nil end

  MM.sleep(POLL_SECONDS)
  keepAlive()
  local st = getJSON(TAN_API .. "/direktfreigabe/authentication/" .. MM.urlencode(job.tanProzessId, "UTF-8"))
  local status = type(st) == "table" and tostring(st["status"] or "") or ""
  dbg("Freigabe-Status: " .. status)

  if status == "DIREKTFREIGABE_OFFEN" or status == "" then
    if credentials[3] == false then
      return askContinueWithoutHistory(job, "Die SecureGo-Freigabe wurde nicht rechtzeitig erteilt.")
    end
    return {
      title     = "DZ Banking: Umsatzhistorie laden",
      challenge = "Bitte die Abfrage der Umsaetze der letzten " .. math.floor(HISTORY_DAYS / 30) ..
                  " Monate fuer Konto ..." .. job.nr:sub(-4) .. " in der App SecureGo plus freigeben.",
      poll      = true
    }
  end

  if status == "DIREKTFREIGABE_BESTAETIGT" then
    MM.printStatus("Historie " .. job.nr .. " laden")
    local list, ok = loadPages(job.kontoID, job.from, job.to, job.currency,
                               {tanProzessId = job.tanProzessId, tanToken = job.tanToken})
    if ok then
      historyCache[job.kontoID] = list
      historyMarks()[job.kontoID] = isoDate(job.to)
      print("DZ Banking " .. job.nr .. ": Historie geladen (" .. #list .. " Umsaetze ab " .. isoDate(job.from) .. ").")
    else
      print("DZ Banking " .. job.nr .. ": Historie trotz Freigabe nicht lesbar -- naechstes Mal erneut.")
    end
    importState.current = nil
    return startNextHistoryImport()
  end

  -- abgelehnt, abgelaufen, Fehler: nachfragen, wie es weitergehen soll
  print("DZ Banking " .. job.nr .. ": Freigabe nicht erteilt (" .. status .. ").")
  return askContinueWithoutHistory(job, "Die SecureGo-Freigabe wurde nicht erteilt (" .. status .. ").")
end

-- Antwort auf die Nachfrage auswerten
local function answerContinueWithoutHistory (credentials)
  local job = importState.ask
  importState.ask = nil
  if isYes(credentials[1]) then
    historyMarks()[job.kontoID] = "declined " .. isoDate(math.floor(os.time()))
    print("DZ Banking " .. job.nr .. ": Einrichtung ohne Altdaten fortgesetzt; fuer einen neuen " ..
          "Versuch HISTORY_RESET = true setzen.")
    return startNextHistoryImport()
  end
  importState = nil
  return "Abgebrochen. Beim naechsten Aktualisieren wird die SecureGo-Freigabe erneut angefragt " ..
         "(oder HISTORY_DAYS = 0 setzen, um ohne Altdaten zu arbeiten)."
end

-- Kapitalbewegungen eines Tages-/Termingeldes aus den Gegenbuchungen der
-- Kontokorrentkonten desselben Unternehmens ableiten. Erkannt werden
-- Buchungen, deren Verwendungszweck die Vertragsnummer (ohne Suffix) und
-- "Kapital" enthaelt; Vorzeichen wird gespiegelt (Abgang KK = Zugang Anlage).
local function mirroredSavingsBookings (savingsAccount, since, currency, det)
  local nr = tostring(savingsAccount["ibanOrVertragID"] or savingsAccount["kontoID"] or "")
  local base = nr:match("^(%d+)") or nr
  if base == "" then return {} end

  -- Die Gegenbuchung nennt nur die Basisnummer (ohne Suffix "-2"). Teilen sich
  -- mehrere Anlagen eine Basisnummer, ist die Zuordnung mehrdeutig: dann wird
  -- nur gespiegelt, wenn der Betrag exakt dem Anlagebetrag entspricht.
  local siblings = 0
  for _, k in ipairs(accountsList or {}) do
    if isSavings(k["kontoart"]) and k["unternehmenID"] == savingsAccount["unternehmenID"] then
      local b = tostring(k["ibanOrVertragID"] or k["kontoID"] or ""):match("^(%d+)")
      if b == base then siblings = siblings + 1 end
    end
  end
  local ambiguous = siblings > 1
  local anlage = amountOf(type(det) == "table" and det["betrag"] or nil)
  if ambiguous then
    print("DZ Banking " .. nr .. ": mehrere Anlagen mit Basisnummer " .. base ..
          " -- Kapitalbewegungen werden nur bei exakt passendem Betrag zugeordnet.")
  end

  local out = {}
  for _, k in ipairs(accountsList or {}) do
    if not isSavings(k["kontoart"]) and k["unternehmenID"] == savingsAccount["unternehmenID"] then
      local kkID = k["kontoID"] or k["ibanOrVertragID"]
      for _, t in ipairs(fetchTransactions(kkID, since, currency)) do
        local text = tostring(t.purpose or "")
        local lower = text:lower()
        local matches = text:find("%f[%d]" .. base .. "%f[%D]") ~= nil
                        and lower:find("kapital", 1, true) ~= nil
                        and lower:find("zinsen", 1, true) == nil
        if matches and ambiguous then
          matches = (anlage ~= nil and math.abs(math.abs(t.amount) - anlage) < 0.005)
        end
        if matches then
          local kkNr = tostring(k["ibanOrVertragID"] or kkID)
          table.insert(out, {
            name          = "DZ BANK AG",
            accountNumber = kkNr:match("^%u%u%d") and kkNr or nil,
            amount        = -t.amount,
            currency      = t.currency,
            bookingDate   = t.bookingDate,
            valueDate     = t.valueDate,
            purpose       = (t.amount < 0 and "Anlage" or "Rückzahlung") ..
                            " Tagesgeld (Gegenbuchung Konto ..." .. kkNr:sub(-4) .. ")",
            bookingText   = t.bookingText,
            booked        = true
          })
        end
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Einsprungspunkte
-- ---------------------------------------------------------------------------

function SupportsBank (protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "DZ Banking"
end

function InitializeSession2 (protocol, bankCode, step, credentials, interactive)
  -- Laufender Erstimport: Wartedialog bzw. Nachfrage
  if importState ~= nil and step > 1 then
    if importState.ask ~= nil then return answerContinueWithoutHistory(credentials) end
    return pollHistoryImport(credentials)
  end
  if step ~= 1 then return "Kein offener Anmeldevorgang -- bitte erneut aktualisieren." end
  MM.printStatus("Anmeldung bei DZ Banking")
  importState = nil

  local username = credentials[1]
  local password = credentials[2]
  if type(username) ~= "string" or username == ""
     or type(password) ~= "string" or password == "" then
    print("DZ Banking: VR-NetKey oder PIN fehlt.")
    return LoginFailed
  end
  dbg(string.format("Zugangsdaten: NetKey %d Zeichen, PIN %d Zeichen", #username, #password))

  local err = login(username, password)
  if err ~= nil then return err end

  -- Erstimport der Historie (einmalig je Konto, nur mit Nutzer am Rechner)
  local ok, queue = pcall(pendingHistoryImports)
  if not ok then
    print("DZ Banking: Pruefung auf Erstimport fehlgeschlagen: " .. tostring(queue))
    return nil
  end
  if #queue == 0 then return nil end
  if interactive == false then
    print("DZ Banking: Erstimport der Umsatzhistorie braucht eine SecureGo-Freigabe -- " ..
          "bitte einmal manuell aktualisieren.")
    return nil
  end
  importState = {queue = queue}
  return startNextHistoryImport()
end

function ListAccounts (knownAccounts)
  local accounts = {}
  for _, k in ipairs(ensureAccounts()) do
    local nr       = tostring(k["ibanOrVertragID"] or k["kontoID"])
    local savings  = isSavings(k["kontoart"])
    local currency = k["waehrung"] or "EUR"
    local name     = savings and "Tagesgeld" or "Kontokorrent"
    local iban, conditions = nil, nil

    if savings then
      local det = tagesgeldDetails(k["kontoID"] or nr)
      if type(det) == "table" then
        name = tostring(det["produktart"] or "TAGESGELD"):lower():gsub("^%l", string.upper)
        conditions = tagesgeldConditions(det)
      end
    else
      local det = kontokorrentDetails(k["kontoID"] or nr)
      if type(det) == "table" then
        local kd = det["kontodetails"] or {}
        name = kd["kontobezeichnung"] or name
        iban = kd["iban"]
        currency = kd["kontowaehrung"] or currency
        conditions = kontokorrentConditions(det)
      end
      if iban == nil and nr:match("^%u%u%d%d") then iban = nr end
    end

    if conditions then print("DZ Banking " .. nr .. ": " .. conditions) end
    if CONDITIONS_MODE == "name" and conditions then name = name .. " (" .. conditions .. ")" end

    local acc = {
      name          = name,
      owner         = k["unternehmenName"],
      accountNumber = nr,
      currency      = currency,
      type          = savings and AccountTypeSavings or AccountTypeGiro
    }
    if iban then acc.iban = iban; acc.bankCode = bankCodeFromIban(iban) end
    table.insert(accounts, acc)
  end

  if #accounts == 0 then return "Die Finanzuebersicht enthaelt keine Konten." end
  return accounts
end

function RefreshAccount (account, since)
  local list = ensureAccounts()
  local k = byNumber[tostring(account.accountNumber)]
  if k == nil then
    -- Rueckfall: nach IBAN oder Konto-ID suchen
    for _, c in ipairs(list) do
      if tostring(c["kontoID"]) == tostring(account.accountNumber)
         or (account.iban and tostring(c["ibanOrVertragID"]) == tostring(account.iban)) then
        k = c
      end
    end
  end
  if k == nil then
    return "Konto " .. tostring(account.accountNumber) .. " ist in der Finanzuebersicht nicht mehr vorhanden."
  end

  keepAlive()
  MM.printStatus("Konto " .. tostring(account.accountNumber))
  local kontoID  = k["kontoID"] or k["ibanOrVertragID"]
  local currency = account.currency or k["waehrung"] or "EUR"

  if isSavings(k["kontoart"]) then
    local det = tagesgeldDetails(kontoID)
    local balance = amountOf(type(det) == "table" and (det["betrag"] or det["betragEur"]) or nil)
                    or amountOf(k["saldoInEUR"]) or 0
    local transactions = {}
    if MIRROR_SAVINGS_BOOKINGS then
      transactions = mirroredSavingsBookings(k, since, currency, det)
      dbg("Spiegelbuchungen fuer " .. tostring(account.accountNumber) .. ": " .. #transactions)
    end
    local conditions = tagesgeldConditions(det)
    if conditions then
      print("DZ Banking " .. tostring(account.accountNumber) .. ": " .. conditions)
      if CONDITIONS_MODE == "pending" then
        table.insert(transactions, 1, conditionsTransaction(conditions, currency))
      end
    end
    return {balance = balance, transactions = transactions}
  end

  local det = kontokorrentDetails(kontoID)
  local balance = amountOf(type(det) == "table" and (det["beschreibung"] or {})["aktuellerKontostand"] or nil)
                  or amountOf(k["saldoInEUR"]) or 0

  local transactions = {}
  local kd = type(det) == "table" and det["kontodetails"] or {}
  if kd["darfUmsaetzeSehen"] == false then
    print("DZ Banking " .. tostring(account.accountNumber) .. ": keine Berechtigung fuer Umsaetze.")
  else
    transactions = fetchTransactions(kontoID, since, currency)
  end

  local conditions = kontokorrentConditions(det)
  if conditions then
    print("DZ Banking " .. tostring(account.accountNumber) .. ": " .. conditions)
    if CONDITIONS_MODE == "pending" then
      table.insert(transactions, 1, conditionsTransaction(conditions, currency))
    end
  end

  return {balance = balance, transactions = transactions}
end

function EndSession ()
  if connection ~= nil then
    pcall(function () connection:close() end)
    connection = nil
  end
  accountsList = nil
  byNumber     = {}
  detailsCache = {}
  txCache      = {}
  historyCache = {}
  importState  = nil
  lastToken    = 0
  return nil
end

dbg("DZ Banking Extension geladen (v1.05)")
