-- MoneyMoney WebBanking Extension für Splitwise (https://www.splitwise.com)
--
-- Zeigt Splitwise als Konto mit Umsätzen: je Ausgabe ein oder zwei Umsätze mit dem
-- Datum der Ausgabe. Zusammen verändern sie deinen Splitwise-Saldo so:
--   * jemand anderes hat bezahlt  → minus dein Anteil
--   * du hast bezahlt             → minus dein Anteil (Ausgabe) und plus der
--                                   gezahlte Betrag als "Zahlung" (Gegenstück zur
--                                   Abbuchung auf dem Bankkonto)
--   * Ausgleichszahlung           → Zahlbetrag, als Umbuchung
-- Die Summe aller Umsätze ist dein Splitwise-Saldo (positiv = man schuldet dir
-- etwas, negativ = du schuldest anderen etwas).
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
  description = 'Splitwise-Ausgaben als Umsätze, Saldo = offene Beträge mit Freunden'
}

-- Ausgaben, die jünger sind, kommen als "vorgemerkt" (booked = false). MoneyMoney
-- ersetzt vorgemerkte Umsätze bei jedem Abruf; spätere Änderungen in Splitwise
-- erzeugen so keine Dubletten.
local pendingDays = 7

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

-- "2026-11-16T06:00:05Z" → POSIX-Zeitstempel (UTC), ohne Abhängigkeit von der
-- lokalen Zeitzone (os.time würde die Felder als Ortszeit lesen).
local function parseIsoUtc (s)
  local y, m, d, H, M, S = string.match(s or '', '^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  -- Tage seit 1970-01-01 (Algorithmus "days_from_civil", H. Hinnant)
  if m <= 2 then y = y - 1 end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp  = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + tonumber(H) * 3600 + tonumber(M) * 60 + tonumber(S)
end

-- 1234.5 → "1.234,50"
local function formatAmount (n)
  local s = string.format('%.2f', math.abs(n))
  local int, frac = string.match(s, '^(%d+)%.(%d+)$')
  int = string.reverse((string.gsub(string.reverse(int), '(%d%d%d)', '%1.')))
  int = string.gsub(int, '^%.', '')
  return (n < 0 and '-' or '') .. int .. ',' .. frac
end

local function joinNames (people)
  local names = {}
  for _, p in ipairs(people) do names[#names + 1] = fullName(p) end
  return table.concat(names, ', ')
end

-- Gruppennamen für den Verwendungszweck; ein Fehler hier ist nicht fatal.
local function loadGroupNames ()
  local names = {}
  local json = apiGet('get_groups')
  if json then
    for _, g in ipairs(json['groups'] or {}) do
      if g['id'] and g['id'] ~= 0 and g['name'] then names[g['id']] = g['name'] end
    end
  end
  return names
end

-- Eine Splitwise-Ausgabe in MoneyMoney-Umsätze übersetzen (leere Liste, wenn sie
-- dich nicht betrifft). Die Summe der Umsätze ist immer dein net_balance:
--   * Ausgleichszahlung      → ein Umsatz über den Zahlbetrag
--   * Ausgabe, andere zahlen → ein Umsatz: minus dein Anteil
--   * Ausgabe, du zahlst     → minus dein Anteil (kategorisierbare Ausgabe) und
--                              plus dein gezahlter Betrag als "Zahlung" (Gegenstück
--                              zur Abbuchung auf dem Bankkonto)
local function expenseToTransactions (expense, myId, accountCurrency, groupNames, now)
  if expense['deleted_at'] ~= nil then return {} end

  local me
  local payers, others = {}, {}
  for _, u in ipairs(expense['users'] or {}) do
    local person = u['user'] or {}
    if u['user_id'] == myId then
      me = u
    else
      if (tonumber(u['paid_share']) or 0) > 0 then payers[#payers + 1] = person end
      if (tonumber(u['owed_share']) or 0) > 0 or (tonumber(u['paid_share']) or 0) > 0 then
        others[#others + 1] = person
      end
    end
  end
  if not me then return {} end

  local net     = tonumber(me['net_balance']) or 0
  local myPaid  = tonumber(me['paid_share']) or 0
  local myShare = tonumber(me['owed_share']) or 0
  local currency = expense['currency_code'] or accountCurrency
  local description = trim(expense['description'] or '')
  local group = groupNames[expense['group_id']]

  local date = parseIsoUtc(expense['date']) or parseIsoUtc(expense['created_at'])
  local created = parseIsoUtc(expense['created_at']) or date
  local recent = math.max(date or 0, created or 0) > now - pendingDays * 86400

  local transactions = {}

  local function add (name, value, bookingText, lines)
    if math.abs(value) < 0.005 then return end
    local purpose = {}
    for _, l in ipairs(lines) do purpose[#purpose + 1] = l end
    if group then purpose[#purpose + 1] = 'Gruppe: ' .. group end

    local amount = convert(value, currency, accountCurrency)
    if currency ~= accountCurrency then
      if amount then
        amount = math.floor(amount * 100 + 0.5) / 100
        purpose[#purpose + 1] = string.format('Originalbetrag %s %s, umgerechnet zum EZB-Kurs vom Abruftag',
          formatAmount(value), currency)
      else
        purpose[#purpose + 1] = string.format('Betrag %s %s — kein EZB-Kurs, nicht umgerechnet',
          formatAmount(value), currency)
        amount = 0
      end
    end

    if name == nil or name == '' then name = 'Splitwise' end
    transactions[#transactions + 1] = {
      name        = name,
      amount      = amount,
      currency    = accountCurrency,
      bookingDate = date,
      valueDate   = date,
      purpose     = table.concat(purpose, '\n'),
      bookingText = bookingText,
      booked      = not recent
    }
  end

  if expense['payment'] == true then
    if net > 0 then
      local name = joinNames(others)
      add(name, net, 'Ausgleichszahlung', { 'Zahlung an ' .. name })
    else
      local name = joinNames(payers)
      add(name, net, 'Ausgleichszahlung', { 'Zahlung von ' .. name })
    end
    return transactions
  end

  local category = expense['category'] and expense['category']['name'] or 'Ausgabe'
  local total = formatAmount(tonumber(expense['cost']) or 0) .. ' ' .. currency

  if myPaid > 0 then
    local paidBy = #payers > 0 and ('dir und ' .. joinNames(payers)) or 'dir'
    add('Du', -myShare, category, { description,
      string.format('Gesamt %s · bezahlt von %s · dein Anteil %s %s',
        total, paidBy, formatAmount(myShare), currency) })
    add('Du', myPaid, 'Zahlung', { description,
      string.format('Von dir bezahlt: %s %s (Gesamt %s) · geteilt mit %s',
        formatAmount(myPaid), currency, total, joinNames(others)) })
  else
    add(joinNames(payers), -myShare, category, { description,
      string.format('Gesamt %s · bezahlt von %s · dein Anteil %s %s',
        total, joinNames(payers), formatAmount(myShare), currency) })
  end

  return transactions
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
      type          = AccountTypeOther
    }
  }
end

function RefreshAccount (account, since)
  local accountCurrency = account.currency or 'EUR'

  -- Saldo: Summe der offenen Beträge mit allen Freunden (wie in der App)
  local friendsJson, err = apiGet('get_friends')
  if not friendsJson then return err end

  local balance = 0
  for _, friend in ipairs(friendsJson['friends'] or {}) do
    for _, b in ipairs(friend['balance'] or {}) do
      local value = tonumber(b['amount'])   -- Splitwise liefert Beträge als String
      if value and b['currency_code'] then
        balance = balance + (convert(value, b['currency_code'], accountCurrency) or 0)
      end
    end
  end

  -- Umsätze: immer die ganze Historie (limit=0 = alle). MoneyMoney erkennt
  -- bereits bekannte Umsätze selbst; so bleibt die Summe gleich dem Saldo.
  local expensesJson
  expensesJson, err = apiGet('get_expenses?limit=0')
  if not expensesJson then return err end

  local groupNames = loadGroupNames()
  local now = os.time()
  local transactions = {}
  local pending = 0
  for _, expense in ipairs(expensesJson['expenses'] or {}) do
    for _, t in ipairs(expenseToTransactions(expense, currentUser['id'], accountCurrency, groupNames, now)) do
      transactions[#transactions + 1] = t
      if not t.booked then pending = pending + t.amount end
    end
  end

  -- MoneyMoney versteht "balance" als Saldo der gebuchten Umsätze und zählt
  -- vorgemerkte selbst dazu (Anzeige "Vorgemerkt"). Ohne diesen Abzug wären
  -- Start-, Tages- und Endsaldo um die vorgemerkten Beträge verschoben.
  balance = balance - pending

  -- pendingBalance (API-Feld "Summe der vorgemerkten Umsätze") meldet die
  -- vorgemerkten Beträge zusätzlich, damit MoneyMoney sie im Kontostand zeigen kann.
  return {
    balance        = math.floor(balance * 100 + 0.5) / 100,
    pendingBalance = math.floor(pending * 100 + 0.5) / 100,
    transactions   = transactions
  }
end

function EndSession ()
  apiKey      = nil
  currentUser = nil
end
