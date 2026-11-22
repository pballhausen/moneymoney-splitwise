-- Offline-Test für Splitwise.lua.
--
-- Stubt die MoneyMoney-Laufzeit (WebBanking, Connection, JSON, Konstanten) und
-- fährt InitializeSession → ListAccounts → RefreshAccount gegen feste Fixtures.
-- Geprüft werden Key-Erkennung, Fehlerbehandlung (401, 403 ohne Pro), Saldo,
-- die Übersetzung von Ausgaben in Umsätze und Fremdwährungen — nicht die
-- Netzwerkschicht.
--
-- Ausführen:  lua test/run_tests.lua

-- --------------------------------------------------------------------------
-- Fixtures (Struktur wie von secure.splitwise.com/api/v3.0 geliefert)
-- --------------------------------------------------------------------------

local KEY = 'abcdefghijklmnopqrstuvwxyz0123456789ABCD'   -- 40 Zeichen
local ME  = 4711

local anna = { first_name = 'Anna', last_name = 'Alpha' }
local ben  = { first_name = 'Ben' }
local self = { first_name = 'Philipp', last_name = 'Test' }

local function share (id, person, paid, owed)
  return { user_id = id, user = person, paid_share = paid, owed_share = owed,
           net_balance = string.format('%.2f', tonumber(paid) - tonumber(owed)) }
end

local function isoDaysAgo (days)
  return os.date('!%Y-%m-%dT%H:%M:%SZ', os.time() - days * 86400)
end

local fixtures = {
  user = {
    user = { id = ME, first_name = 'Philipp', last_name = 'Test',
             email = 'philipp@example.com', default_currency = 'EUR' }
  },

  friends = {
    friends = {
      { id = 1, first_name = 'Anna', last_name = 'Alpha',
        balance = { { currency_code = 'EUR', amount = '12.5' } } },
      { id = 2, first_name = 'Ben',
        balance = { { currency_code = 'EUR', amount = '-7.25' },
                    { currency_code = 'USD', amount = '20.0' } } },
      { id = 3, first_name = 'Carla', balance = {} }
    }
  },

  groups = {
    groups = { { id = 0, name = 'Ausgabe ohne Gruppe' }, { id = 55, name = 'Sizilien' } }
  },

  expenses = {
    expenses = {
      -- 1: Anna hat bezahlt, du schuldest deinen Anteil; vor 10 Tagen nachgetragen
      -- (älter als die 7-Tage-Vormerkfrist → gebucht)
      { id = 101, description = 'Olivenöl', cost = '72.0', currency_code = 'EUR',
        date = '2025-03-10T18:30:00Z', created_at = isoDaysAgo(10),
        payment = false, group_id = 55, category = { name = 'Lebensmittel' },
        users = { share(1, anna, '72.0', '18.0'), share(ME, self, '0.0', '18.0'),
                  share(2, ben, '0.0', '36.0') } },
      -- 2: du hast bezahlt, Ben schuldet dir die Hälfte
      { id = 102, description = 'Restaurant', cost = '1234.5', currency_code = 'EUR',
        date = '2024-02-29T12:00:00Z', created_at = '2024-02-29T12:00:00Z',
        payment = false, group_id = nil, category = { name = 'Restaurant' },
        users = { share(ME, self, '1234.5', '617.25'), share(2, ben, '0.0', '617.25') } },
      -- 3: Anna zahlt dir Geld zurück
      { id = 103, description = 'Payment', cost = '30.0', currency_code = 'EUR',
        date = '2025-04-01T09:00:00Z', created_at = '2025-04-01T09:00:00Z',
        payment = true, category = { name = 'Allgemein' },
        users = { share(1, anna, '30.0', '0.0'), share(ME, self, '0.0', '30.0') } },
      -- 4: du zahlst Ben
      { id = 104, description = 'Payment', cost = '7.25', currency_code = 'EUR',
        date = '2025-04-02T09:00:00Z', created_at = '2025-04-02T09:00:00Z',
        payment = true, category = { name = 'Allgemein' },
        users = { share(ME, self, '7.25', '0.0'), share(2, ben, '0.0', '7.25') } },
      -- 5: gelöscht
      { id = 105, description = 'Gelöscht', cost = '10.0', currency_code = 'EUR',
        date = '2025-05-01T09:00:00Z', created_at = '2025-05-01T09:00:00Z',
        deleted_at = '2025-05-02T09:00:00Z', payment = false,
        users = { share(1, anna, '10.0', '5.0'), share(ME, self, '0.0', '5.0') } },
      -- 6: du bist nicht beteiligt
      { id = 106, description = 'Fremd', cost = '10.0', currency_code = 'EUR',
        date = '2025-05-01T09:00:00Z', created_at = '2025-05-01T09:00:00Z', payment = false,
        users = { share(1, anna, '10.0', '5.0'), share(2, ben, '0.0', '5.0') } },
      -- 7: du hast genau deinen Anteil bezahlt → Saldo unverändert
      { id = 107, description = 'Neutral', cost = '10.0', currency_code = 'EUR',
        date = '2025-05-01T09:00:00Z', created_at = '2025-05-01T09:00:00Z', payment = false,
        users = { share(ME, self, '5.0', '5.0'), share(1, anna, '5.0', '5.0') } },
      -- 8: Fremdwährung USD
      { id = 108, description = 'Diner', cost = '40.0', currency_code = 'USD',
        date = '2025-06-01T20:00:00Z', created_at = '2025-06-01T20:00:00Z',
        payment = false, category = { name = 'Restaurant' },
        users = { share(2, ben, '40.0', '20.0'), share(ME, self, '0.0', '20.0') } },
      -- 9: frisch angelegt → vorgemerkt
      { id = 109, description = 'Taxi', cost = '20.0', currency_code = 'EUR',
        date = isoDaysAgo(1), created_at = isoDaysAgo(1),
        payment = false, category = { name = 'Taxi' },
        users = { share(1, anna, '20.0', '10.0'), share(ME, self, '0.0', '10.0') } },
      -- 11: du zahlst alles, dein Anteil 0 (z. B. Vorschuss) → nur "Zahlung"
      { id = 111, description = 'Abschlag', cost = '240.0', currency_code = 'EUR',
        date = '2025-08-01T10:00:00Z', created_at = '2025-08-01T10:00:00Z',
        payment = false, category = { name = 'Allgemein' },
        users = { share(ME, self, '240.0', '0.0'), share(2, ben, '0.0', '240.0') } },
      -- 10: Währung ohne EZB-Kurs
      { id = 110, description = 'Markt', cost = '2000', currency_code = 'XAF',
        date = '2025-07-01T10:00:00Z', created_at = '2025-07-01T10:00:00Z', payment = false,
        users = { share(1, anna, '2000', '1000'), share(ME, self, '0', '1000') } }
    }
  },

  unauthorized = { error = 'Invalid API request: you are not logged in' },

  noPro = { errors = { base = {
    'Diese App kann derzeit nicht auf Splitwise zugreifen, da ihr Entwickler kein ' ..
    'aktives Splitwise Pro-Abonnement hat. Bitte wende dich an den Entwickler der App, um Hilfe zu erhalten.'
  } } }
}

local ecbXml = [[
<Cube time='2026-11-17'>
  <Cube currency='USD' rate='1.0800'/>
  <Cube currency='GBP' rate='0.8500'/>
</Cube>]]

-- --------------------------------------------------------------------------
-- MoneyMoney-Laufzeit stubben
-- --------------------------------------------------------------------------

ProtocolWebBanking = 'ProtocolWebBanking'
AccountTypeOther   = 'AccountTypeOther'
LoginFailed        = 'LoginFailed'

local requests = {}
local scenario = 'ok'

function WebBanking (spec)
  _G.__spec = spec
end

function Connection ()
  return {
    request = function (self, method, url, body, contentType, headers)
      requests[#requests + 1] = { method = method, url = url, headers = headers or {} }

      if string.find(url, 'ecb.europa.eu', 1, true) then
        return ecbXml
      end
      if scenario == 'unauthorized' then return 'FIXTURE:unauthorized' end
      if scenario == 'noPro'        then return 'FIXTURE:noPro' end
      if string.find(url, 'get_current_user', 1, true) then return 'FIXTURE:user' end
      if string.find(url, 'get_friends', 1, true)      then return 'FIXTURE:friends' end
      if string.find(url, 'get_groups', 1, true)       then return 'FIXTURE:groups' end
      if string.find(url, 'get_expenses', 1, true)     then return 'FIXTURE:expenses' end
      error('unerwarteter Request: ' .. url)
    end
  }
end

function JSON (str)
  local key = string.match(str or '', '^FIXTURE:(%w+)$')
  local value = key and fixtures[key] or {}
  return { dictionary = function () return value end }
end

-- --------------------------------------------------------------------------
-- Test-Helfer
-- --------------------------------------------------------------------------

local failures = 0

local function check (name, actual, expected)
  if actual ~= expected then
    failures = failures + 1
    print(string.format('FAIL  %s\n        erwartet: %s\n        bekommen: %s',
      name, tostring(expected), tostring(actual)))
  else
    print(string.format('ok    %s  (%s)', name, tostring(actual)))
  end
end

local function round (n)
  if n == nil then return nil end
  return math.floor(n * 100 + 0.5) / 100
end

local function contains (s, needle)
  return string.find(tostring(s), needle, 1, true) ~= nil
end

-- Umsatz anhand der ersten Zeile des Verwendungszwecks (und optional des
-- Buchungstexts) finden
local function byPurpose (transactions, firstLine, bookingText)
  for _, t in ipairs(transactions) do
    if string.match(t.purpose or '', '^[^\n]*') == firstLine
       and (bookingText == nil or t.bookingText == bookingText) then return t end
  end
end

-- --------------------------------------------------------------------------
-- Ablauf
-- --------------------------------------------------------------------------

dofile('Splitwise.lua')

check('version ist Zahl', type(__spec.version), 'number')
check('SupportsBank: Splitwise', SupportsBank(ProtocolWebBanking, 'Splitwise'), true)
check('SupportsBank: fremde Bank', SupportsBank(ProtocolWebBanking, 'become.1'), false)

-- Kein Key
check('ohne Key: Fehlermeldung',
  contains(InitializeSession(ProtocolWebBanking, 'Splitwise', '', '', ''), 'API-Key'), true)

-- Key im Benutzernamen (Variante der alten Extension), "dummy" als Passwort
check('Key im Benutzernamen', InitializeSession(ProtocolWebBanking, 'Splitwise', KEY, '', 'dummy'), nil)
check('Bearer-Header', requests[#requests].headers['Authorization'], 'Bearer ' .. KEY)
check('Accept-Header JSON', requests[#requests].headers['Accept'], 'application/json')
check('URL get_current_user', requests[#requests].url,
  'https://secure.splitwise.com/api/v3.0/get_current_user')

-- Key im Passwort, Benutzername als Anzeigename
check('Key im Passwort', InitializeSession(ProtocolWebBanking, 'Splitwise', 'Splitwise', '', KEY), nil)
check('Key aus Passwort genutzt', requests[#requests].headers['Authorization'], 'Bearer ' .. KEY)

local accounts = ListAccounts({})
check('ein Konto', #accounts, 1)
check('Kontotyp Sonstiges (Umsätze statt Depot)', accounts[1].type, AccountTypeOther)
check('kein Depot', accounts[1].portfolio, nil)
check('Kontonummer wie alte Extension', accounts[1].accountNumber, 'philipp@example.com (4711)')
check('Kontowährung = default_currency', accounts[1].currency, 'EUR')
check('Inhaber', accounts[1].owner, 'Philipp Test')

local result = RefreshAccount(accounts[1], 0)
local tx = result.transactions

-- Saldo aus get_friends: 12,50 − 7,25 + 20 USD / 1,08 = 23,77, davon −10 (Taxi)
-- vorgemerkt. MoneyMoney zählt Vorgemerktes selbst dazu → gebuchter Saldo 33,77.
check('Saldo = gebuchter Teil (ohne vorgemerktes Taxi)', result.balance, 33.77)
local pendingSum = 0
for _, t in ipairs(result.transactions) do
  if not t.booked then pendingSum = pendingSum + t.amount end
end
check('gebucht + vorgemerkt = Splitwise-Gesamtsaldo', round(result.balance + pendingSum), 23.77)
check('pendingBalance = Summe der vorgemerkten Umsätze', result.pendingBalance, round(pendingSum))
check('pendingBalance = vorgemerktes Taxi', result.pendingBalance, -10)
check('ganze Historie abgefragt', contains(requests[#requests - 1].url, 'get_expenses?limit=0')
  or contains(requests[#requests].url, 'get_expenses?limit=0'), true)

check('elf Umsätze (gelöscht, fremd ausgelassen; selbst bezahlte doppelt)', #tx, 11)
check('gelöschte Ausgabe fehlt', byPurpose(tx, 'Gelöscht'), nil)
check('fremde Ausgabe fehlt', byPurpose(tx, 'Fremd'), nil)

local oil = byPurpose(tx, 'Olivenöl')
check('andere zahlen: minus dein Anteil', oil and oil.amount, -18)
check('andere zahlen: Name = wer bezahlt hat', oil and oil.name, 'Anna Alpha')
check('Kategorie als Buchungstext', oil and oil.bookingText, 'Lebensmittel')
check('Verwendungszweck: Gesamt/Anteil', contains(oil and oil.purpose,
  'Gesamt 72,00 EUR · bezahlt von Anna Alpha · dein Anteil 18,00 EUR'), true)
check('Verwendungszweck: Gruppe', contains(oil and oil.purpose, 'Gruppe: Sizilien'), true)
check('vor 10 Tagen angelegt: gebucht (Frist 7 Tage)', oil and oil.booked, true)
check('Umsatzwährung = Kontowährung', oil and oil.currency, 'EUR')
check('andere zahlen: keine Zahlung', byPurpose(tx, 'Olivenöl', 'Zahlung'), nil)

-- Du zahlst 1.234,50, ihr teilt 50/50: Ausgabe −617,25 + Zahlung +1.234,50 = +617,25
local dinner = byPurpose(tx, 'Restaurant', 'Restaurant')
local dinnerPay = byPurpose(tx, 'Restaurant', 'Zahlung')
check('du zahlst: Ausgabe = minus dein Anteil', dinner and dinner.amount, -617.25)
check('du zahlst: Ausgabe mit Kategorie', dinner and dinner.bookingText, 'Restaurant')
check('du zahlst: Name "Du"', dinner and dinner.name, 'Du')
check('Tausenderpunkt, "bezahlt von dir"', contains(dinner and dinner.purpose,
  'Gesamt 1.234,50 EUR · bezahlt von dir · dein Anteil 617,25 EUR'), true)
check('du zahlst: Zahlung = gezahlter Betrag', dinnerPay and dinnerPay.amount, 1234.5)
check('Zahlung: Zweck nennt Mitzahler', contains(dinnerPay and dinnerPay.purpose,
  'Von dir bezahlt: 1.234,50 EUR (Gesamt 1.234,50 EUR) · geteilt mit Ben'), true)
check('Ausgabe + Zahlung = Saldoänderung', dinner.amount + dinnerPay.amount, 617.25)
check('Buchungsdatum UTC (2024-02-29 12:00Z)', dinner and dinner.bookingDate, 1709208000)
check('Zahlung gleiches Datum', dinnerPay and dinnerPay.bookingDate, 1709208000)
check('ohne Gruppe keine Gruppenzeile', contains(dinner and dinner.purpose, 'Gruppe:'), false)

-- Genau deinen Anteil bezahlt: Saldo unverändert, Ausgabe trotzdem sichtbar
local neutral = byPurpose(tx, 'Neutral', 'Ausgabe')
local neutralPay = byPurpose(tx, 'Neutral', 'Zahlung')
check('eigener Anteil selbst bezahlt: Ausgabe −5', neutral and neutral.amount, -5)
check('eigener Anteil selbst bezahlt: Zahlung +5', neutralPay and neutralPay.amount, 5)
check('mehrere Zahler im Zweck', contains(neutral and neutral.purpose, 'bezahlt von dir und Anna Alpha'), true)

-- Anteil 0 (Vorschuss): nur die Zahlung, keine 0-€-Ausgabe
check('Anteil 0: keine Ausgabe', byPurpose(tx, 'Abschlag', 'Allgemein'), nil)
local advance = byPurpose(tx, 'Abschlag', 'Zahlung')
check('Anteil 0: Zahlung +240', advance and advance.amount, 240)

local fromAnna = byPurpose(tx, 'Zahlung von Anna Alpha')
check('Zahlung erhalten: negativ', fromAnna and fromAnna.amount, -30)
check('Zahlung: Buchungstext', fromAnna and fromAnna.bookingText, 'Ausgleichszahlung')

local toBen = byPurpose(tx, 'Zahlung an Ben')
check('Zahlung geleistet: positiv', toBen and toBen.amount, 7.25)
check('Zahlung geleistet: Name', toBen and toBen.name, 'Ben')

local usd = byPurpose(tx, 'Diner')
check('USD in EUR umgerechnet (−20 / 1,08)', round(usd and usd.amount), -18.52)
check('USD: Originalbetrag im Zweck', contains(usd and usd.purpose, 'Originalbetrag -20,00 USD'), true)

local taxi = byPurpose(tx, 'Taxi')
check('frische Ausgabe vorgemerkt', taxi and taxi.booked, false)

local market = byPurpose(tx, 'Markt')
check('unbekannter Kurs: Betrag 0', market and market.amount, 0)
check('unbekannter Kurs: Hinweis im Zweck', contains(market and market.purpose, 'kein EZB-Kurs'), true)

-- 401: abgelaufener/falscher Key → LoginFailed (MoneyMoney pausiert dann den Abruf)
scenario = 'unauthorized'
check('401 → LoginFailed', InitializeSession(ProtocolWebBanking, 'Splitwise', KEY, '', ''), LoginFailed)

-- 403 ohne Pro → verständliche Meldung, kein LoginFailed
scenario = 'noPro'
local msg = InitializeSession(ProtocolWebBanking, 'Splitwise', KEY, '', '')
check('403 ohne Pro: kein LoginFailed', msg ~= LoginFailed, true)
check('403 ohne Pro: Meldung nennt Splitwise Pro', contains(msg, 'Splitwise Pro'), true)

-- Fehler beim Abruf wird gemeldet, nicht still als leeres Konto
check('Fehler in RefreshAccount wird gemeldet',
  contains(RefreshAccount(accounts[1], 0), 'Splitwise Pro'), true)
scenario = 'ok'

EndSession()

print('')
if failures == 0 then
  print('Alle Tests bestanden.')
else
  print(failures .. ' Test(s) fehlgeschlagen.')
  os.exit(1)
end
