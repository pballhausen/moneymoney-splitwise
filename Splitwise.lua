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
-- Darstellung: Name (fett in MoneyMoney) = Splitwise-Beschreibung ("Benzin"),
-- Verwendungszweck = Gruppe · Rolle bzw. Zahler · Details, Buchungstext = Kategorie.
-- Ausgleichszahlungen heißen "Ausgleich an/von <Name>".
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

-- Alle Umsätze kommen sofort als gebucht. MoneyMoney kann gebuchte Umsätze nicht
-- nachträglich ändern; ändert sich eine Ausgabe in Splitwise, liefert die Extension
-- deshalb eine Korrekturbuchung über die Differenz (gelöscht → Storno). Was schon in
-- MoneyMoney steht, merkt sie sich in LocalStorage und prüft es über
-- isKnownTransactionId nach (Kennung je Umsatz: "sw:<Ausgabe>:<Rolle>").

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
--
-- Rückgabe: Liste von { role, value (Betrag in Ausgabewährung), currency, tx }.
-- role ist "anteil", "zahlung" oder "ausgleich" und bildet mit der Ausgaben-ID die
-- feste Kennung des Umsatzes.
local function expenseToTransactions (expense, myId, accountCurrency, groupNames)

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

  local transactions = {}

  -- Name (fett in MoneyMoney) = wofür; Zweck = eine Zeile, Wichtigstes zuerst
  -- (MoneyMoney kürzt hinten): Gruppe · Rolle/Zahler · Details.
  local function add (role, name, value, bookingText, parts)
    if math.abs(value) < 0.005 then return end
    local purpose = {}
    if group then purpose[#purpose + 1] = group end
    for _, p in ipairs(parts) do
      if p and p ~= '' then purpose[#purpose + 1] = p end
    end

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
      role     = role,
      value    = value,
      currency = currency,
      tx = {
        name        = name,
        amount      = amount,
        currency    = accountCurrency,
        bookingDate = date,
        valueDate   = date,
        purpose     = table.concat(purpose, ' · '),
        bookingText = bookingText,
        booked      = true
      }
    }
  end

  if expense['payment'] == true then
    if net > 0 then
      add('ausgleich', 'Ausgleich an ' .. joinNames(others), net, 'Ausgleichszahlung',
        { 'Ausgleichszahlung' })
    else
      add('ausgleich', 'Ausgleich von ' .. joinNames(payers), net, 'Ausgleichszahlung',
        { 'Ausgleichszahlung' })
    end
    return transactions
  end

  local category = expense['category'] and expense['category']['name'] or 'Ausgabe'
  local total = 'Gesamt ' .. formatAmount(tonumber(expense['cost']) or 0) .. ' ' .. currency
  if description == '' then description = category end

  if myPaid > 0 then
    local paidBy = #payers > 0 and ('dir und ' .. joinNames(payers)) or 'dir'
    local sharedWith = joinNames(others)
    add('anteil', description, -myShare, category,
      { 'dein Anteil', total .. ', bezahlt von ' .. paidBy })
    add('zahlung', description, myPaid, 'Zahlung',
      { 'deine Zahlung', sharedWith ~= '' and ('geteilt mit ' .. sharedWith) or nil })
  else
    add('anteil', description, -myShare, category,
      { 'bezahlt von ' .. joinNames(payers), total })
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

local roles = { 'anteil', 'zahlung', 'ausgleich' }

local function round2 (n)
  return math.floor(n * 100 + 0.5) / 100
end

-- 1709208000 → "29.02.2024"
local function formatDate (ts)
  return os.date('!%d.%m.%Y', ts or 0)
end

-- Gemerkter Stand je Ausgabe und Rolle: was MoneyMoney bereits gebucht hat.
--   value       Summe in Ausgabewährung (Original + Korrekturen)
--   amount      dieselbe Summe in Kontowährung (so wie gebucht)
--   corrections Anzahl gelieferter Korrekturbuchungen (für deren Kennung)
--   name, bookingText, title, date  für Korrekturen, falls die Rolle wegfällt
local function loadState ()
  if type(LocalStorage) ~= 'table' then return {} end
  if type(LocalStorage.expenses) ~= 'table' then LocalStorage.expenses = {} end
  return LocalStorage.expenses
end

-- Stand aus MoneyMoney rekonstruieren, wenn LocalStorage leer ist (z.B. nach neu
-- eingerichtetem Bankzugang): Original und Korrekturen über ihre Kennung abfragen.
local function recoverFromMoneyMoney (known, key, original, target, accountCurrency)
  local amount, n = original.amount or 0, 0
  while true do
    local c = known(key .. ':k' .. (n + 1))
    if not c then break end
    amount = amount + (c.amount or 0)
    n = n + 1
  end
  local currency = target and target.currency or accountCurrency
  local value = amount
  if currency ~= accountCurrency then
    value = convert(amount, accountCurrency, currency) or (target and target.value) or 0
  end
  return {
    value       = value,
    currency    = currency,
    amount      = amount,
    corrections = n,
    name        = original.name,
    bookingText = target and target.tx.bookingText or nil,
    title       = nil,
    date        = original.bookingDate
  }
end

-- Korrekturbuchung über die Differenz zwischen gebuchtem Stand und Splitwise.
-- Name wie das Original; Zweck: Gruppe · Korrektur <n> · was sich geändert hat.
-- "Korrektur <n>" muss im Zweck stehen, sonst hält MoneyMoney zwei gleich hohe
-- Korrekturen am selben Tag für Dubletten.
local function correction (key, prev, target, newValue, deltaAmount, expense, deleted, groupNames)
  local n = (prev.corrections or 0) + 1
  local when = deleted and parseIsoUtc(expense['deleted_at'])
            or parseIsoUtc(expense['updated_at']) or os.time()
  local currency = target and target.currency or prev.currency

  local parts = {}
  local group = groupNames[expense['group_id']]
  if group then parts[#parts + 1] = group end
  if deleted then
    parts[#parts + 1] = 'Storno (Korrektur ' .. n .. ')'
    parts[#parts + 1] = string.format('in Splitwise gelöscht · Ausgabe vom %s über %s %s',
      formatDate(prev.date), formatAmount(prev.value), prev.currency)
  else
    parts[#parts + 1] = 'Korrektur ' .. n
    parts[#parts + 1] = string.format('in Splitwise geändert · Ausgabe vom %s · vorher %s %s, jetzt %s %s',
      formatDate(target and target.tx.bookingDate or prev.date),
      formatAmount(prev.value), prev.currency, formatAmount(newValue), currency)
  end

  return {
    name          = target and target.tx.name or prev.name or prev.title or 'Splitwise',
    amount        = round2(deltaAmount),
    currency      = nil,  -- wird vom Aufrufer gesetzt
    bookingDate   = when,
    valueDate     = when,
    purpose       = table.concat(parts, ' · '),
    bookingText   = target and target.tx.bookingText or prev.bookingText,
    booked        = true,
    transactionId = key .. ':k' .. n
  }, n
end

function RefreshAccount (account, since, isKnownTransactionId)
  local accountCurrency = account.currency or 'EUR'
  local known = type(isKnownTransactionId) == 'function' and isKnownTransactionId or nil

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

  -- Ausgaben: immer die ganze Historie (limit=0 = alle), inklusive gelöschter
  -- (deleted_at gesetzt) — nur so lassen sich Löschungen stornieren.
  local expensesJson
  expensesJson, err = apiGet('get_expenses?limit=0')
  if not expensesJson then return err end

  local groupNames = loadGroupNames()
  local state = loadState()
  local transactions = {}

  for _, expense in ipairs(expensesJson['expenses'] or {}) do
    local expId = tostring(expense['id'])
    local deleted = expense['deleted_at'] ~= nil

    local targets = {}
    if not deleted then
      for _, e in ipairs(expenseToTransactions(expense, currentUser['id'], accountCurrency, groupNames)) do
        targets[e.role] = e
      end
    end

    local stored = state[expId] or {}
    for _, role in ipairs(roles) do
      local key = 'sw:' .. expId .. ':' .. role
      local target = targets[role]

      -- Was steht schon in MoneyMoney? LocalStorage ist die erste Quelle; kennt
      -- MoneyMoney den Umsatz nicht (Konto neu angelegt), gilt er als neu.
      local prev = stored[role]
      if known then
        local original = known(key)
        if not original then
          prev = nil
        elseif not prev then
          prev = recoverFromMoneyMoney(known, key, original, target, accountCurrency)
        end
      end

      if not prev then
        if target then
          target.tx.transactionId = key
          transactions[#transactions + 1] = target.tx
          stored[role] = {
            value       = target.value,
            currency    = target.currency,
            amount      = target.tx.amount,
            corrections = 0,
            name        = target.tx.name,
            bookingText = target.tx.bookingText,
            title       = trim(expense['description'] or ''),
            date        = target.tx.bookingDate
          }
        end
      else
        local newValue = target and target.value or 0
        local newCurrency = target and target.currency or prev.currency
        local deltaAmount
        if newCurrency == prev.currency then
          local deltaValue = newValue - (prev.value or 0)
          if math.abs(deltaValue) < 0.005 then
            deltaAmount = 0
          elseif newCurrency == accountCurrency then
            deltaAmount = deltaValue
          else
            deltaAmount = convert(deltaValue, newCurrency, accountCurrency) or 0
          end
        else
          deltaAmount = (target and target.tx.amount or 0) - (prev.amount or 0)
        end

        if math.abs(deltaAmount) >= 0.005 then
          local tx, n = correction(key, prev, target, newValue, deltaAmount, expense, deleted, groupNames)
          tx.currency = accountCurrency
          transactions[#transactions + 1] = tx
          prev.amount = round2((prev.amount or 0) + tx.amount)
          prev.corrections = n
        end
        prev.value = newValue
        prev.currency = newCurrency
        if target then
          prev.name = target.tx.name
          prev.bookingText = target.tx.bookingText
          prev.date = target.tx.bookingDate
        end
        if trim(expense['description'] or '') ~= '' then prev.title = trim(expense['description']) end
        stored[role] = prev
      end
    end
    if next(stored) ~= nil then state[expId] = stored end
  end

  return {
    balance      = round2(balance),
    transactions = transactions
  }
end

function EndSession ()
  apiKey      = nil
  currentUser = nil
end
