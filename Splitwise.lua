-- MoneyMoney WebBanking Extension für Splitwise (https://www.splitwise.com)
--
-- Ruft die offenen Salden mit allen Splitwise-Freunden ab und zeigt sie als
-- Depot: je Freund und Währung eine Position. Positiv = der Freund schuldet dir
-- etwas, negativ = du schuldest ihm etwas.
--
-- Neufassung auf Basis von https://github.com/slauber/moneymoney-splitwise
-- (Copyright (c) 2022 Sebastian Lauber, MIT-Lizenz, siehe LICENSE).
--
-- Login in MoneyMoney:
--   Dienst:  Splitwise
--   Feld 1:  Splitwise-API-Key (MoneyMoney beschriftet das Feld für den Dienst
--            "Splitwise" als API-Key; technisch kommt es als username an)
--   Feld 2:  falls MoneyMoney eins verlangt, beliebig, z.B. "dummy". Steht der
--            Key stattdessen hier, wird er ebenfalls erkannt.
--
-- Achtung: Splitwise lässt API-Zugriffe seit Herbst 2026 nur noch zu, wenn das
-- Konto, das die API-App registriert hat, ein aktives Splitwise Pro hat.
-- Ohne Pro antwortet die API mit HTTP 403 — die Extension meldet das im Klartext.

WebBanking{
  version     = 2.0,
  url         = 'https://secure.splitwise.com',
  services    = {'Splitwise'},
  description = 'Offene Salden mit Splitwise-Freunden als Depot'
}

local apiBase = 'https://secure.splitwise.com/api/v3.0/'
local ecbUrl  = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml'

local connection
local apiKey
local currentUser

-- ---------------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------------

local function trim (s)
  return (string.gsub(s or '', '^%s*(.-)%s*$', '%1'))
end

-- Splitwise-API-Keys sind 40 Zeichen lang; ein "dummy"-Passwort ist es nicht.
local function looksLikeKey (s)
  return s ~= nil and #trim(s) >= 30 and not string.find(trim(s), '%s')
end

local function pickApiKey (username, password)
  if looksLikeKey(username) then return trim(username) end
  if looksLikeKey(password) then return trim(password) end
  return nil
end

local function fullName (person)
  local first = person['first_name'] or ''
  local last  = person['last_name'] or ''
  local name  = trim(first .. ' ' .. last)
  if name == '' then name = person['email'] or ('Splitwise-Nutzer ' .. tostring(person['id'])) end
  return name
end

-- Splitwise liefert Fehler in zwei Formen:
--   {"error": "Invalid API request: you are not logged in"}            (401)
--   {"errors": {"base": ["Diese App kann derzeit nicht ... Pro ..."]}} (403 u.a.)
local function extractError (json)
  if type(json) ~= 'table' then return nil end
  if type(json['error']) == 'string' then return json['error'] end
  local errors = json['errors']
  if type(errors) == 'table' then
    local parts = {}
    for key, list in pairs(errors) do
      if type(list) == 'table' then
        for _, msg in ipairs(list) do parts[#parts + 1] = tostring(msg) end
      elseif type(list) == 'string' then
        parts[#parts + 1] = (key == 'base') and list or (key .. ': ' .. list)
      end
    end
    if #parts > 0 then return table.concat(parts, ' ') end
  end
  return nil
end

local function isAuthError (msg)
  local m = string.lower(msg or '')
  return string.find(m, 'not logged in', 1, true) ~= nil
      or string.find(m, 'invalid api key', 1, true) ~= nil
      or string.find(m, 'unauthorized', 1, true) ~= nil
end

local function isProError (msg)
  local m = string.lower(msg or '')
  return string.find(m, 'pro', 1, true) ~= nil
     and (string.find(m, 'abonnement', 1, true) ~= nil or string.find(m, 'subscription', 1, true) ~= nil)
end

-- GET gegen die Splitwise-API. Gibt (daten, nil) oder (nil, fehlertext, istAuthFehler) zurück.
local function apiGet (endpoint)
  local headers = {
    ['Authorization'] = 'Bearer ' .. apiKey,
    -- Mit Accept: application/json gibt MoneyMoney die Antwort auch bei
    -- HTTP-Fehlern an das Skript zurück, statt hart abzubrechen.
    ['Accept']        = 'application/json'
  }
  local ok, content = pcall(function ()
    return connection:request('GET', apiBase .. endpoint, nil, nil, headers)
  end)
  if not ok then
    return nil, 'Splitwise nicht erreichbar: ' .. tostring(content)
  end

  local parsed, json = pcall(function () return JSON(content):dictionary() end)
  if not parsed or type(json) ~= 'table' then
    return nil, 'Splitwise: unerwartete Antwort (kein JSON).'
  end

  local err = extractError(json)
  if err then
    if isProError(err) then
      return nil, 'Splitwise verweigert den API-Zugriff: Das Konto, das die API-App ' ..
                  'registriert hat, braucht ein aktives Splitwise Pro. (' .. err .. ')'
    end
    return nil, 'Splitwise: ' .. err, isAuthError(err)
  end
  return json
end

-- Wechselkurse der EZB (1 EUR = x Fremdwährung). Nur geladen, wenn nötig.
local ecbRates

local function loadEcbRates ()
  if ecbRates then return ecbRates end
  ecbRates = { EUR = 1 }
  local ok, xml = pcall(function ()
    return Connection():request('GET', ecbUrl)
  end)
  if ok and type(xml) == 'string' then
    for code, rate in string.gmatch(xml, "currency='(%u%u%u)'%s+rate='([%d%.]+)'") do
      ecbRates[code] = tonumber(rate)
    end
  end
  return ecbRates
end

-- Betrag von "from" in "to" umrechnen; nil, wenn kein Kurs bekannt ist.
local function convert (amount, from, to)
  if from == to then return amount end
  local rates = loadEcbRates()
  local rFrom, rTo = rates[from], rates[to]
  if not rFrom or not rTo then return nil end
  return amount * rTo / rFrom
end

-- ---------------------------------------------------------------------------
-- MoneyMoney-Schnittstelle
-- ---------------------------------------------------------------------------

function SupportsBank (protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == 'Splitwise'
end

function InitializeSession (protocol, bankCode, username, customer, password)
  connection = Connection()
  ecbRates   = nil

  apiKey = pickApiKey(username, password)
  if not apiKey then
    return 'Kein Splitwise-API-Key gefunden. Den Key unter secure.splitwise.com/apps ' ..
           '→ deine App → "API key" erzeugen und in MoneyMoney eintragen.'
  end

  local json, err, authFailed = apiGet('get_current_user')
  if not json then
    if authFailed then return LoginFailed end
    return err
  end

  currentUser = json['user']
  if type(currentUser) ~= 'table' or currentUser['id'] == nil then
    return 'Splitwise: Antwort von get_current_user ohne Nutzerdaten.'
  end
end

function ListAccounts (knownAccounts)
  local currency = currentUser['default_currency']
  if type(currency) ~= 'string' or #currency ~= 3 then currency = 'EUR' end

  return {
    {
      name          = 'Splitwise',
      owner         = fullName(currentUser),
      -- Format der alten Extension beibehalten, damit bestehende Konten passen
      accountNumber = string.format('%s (%s)', tostring(currentUser['email'] or ''), tostring(currentUser['id'])),
      currency      = currency,
      portfolio     = true,
      type          = AccountTypePortfolio
    }
  }
end

function RefreshAccount (account, since)
  local json, err = apiGet('get_friends')
  if not json then return err end

  local accountCurrency = account.currency or 'EUR'
  local securities = {}

  for _, friend in ipairs(json['friends'] or {}) do
    local balances = {}
    for _, b in ipairs(friend['balance'] or {}) do
      local value = tonumber(b['amount'])   -- Splitwise liefert Beträge als String
      if value and math.abs(value) >= 0.005 and b['currency_code'] then
        balances[#balances + 1] = { currency = b['currency_code'], value = value }
      end
    end

    local name = fullName(friend)
    for _, b in ipairs(balances) do
      local label = name
      if #balances > 1 or b.currency ~= accountCurrency then
        label = name .. ' (' .. b.currency .. ')'
      end

      -- amount = Wert in Kontowährung, originalAmount = Wert in Originalwährung
      local security = { name = label }

      if b.currency == accountCurrency then
        security.amount = b.value
      else
        security.originalAmount           = b.value
        security.currencyOfOriginalAmount = b.currency
        -- Ohne bekannten Kurs bleibt amount leer, statt einen falschen Wert zu zeigen
        security.amount = convert(b.value, b.currency, accountCurrency)
      end

      securities[#securities + 1] = security
    end
  end

  return { securities = securities }
end

function EndSession ()
  apiKey      = nil
  currentUser = nil
end
