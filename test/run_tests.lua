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
      -- 1: Anna hat bezahlt, du schuldest deinen Anteil
      { id = 101, description = 'Olivenöl', cost = '72.0', currency_code = 'EUR',
        date = '2025-03-10T18:30:00Z', created_at = '2025-03-10T18:31:00Z',
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
      -- 9: frisch angelegt → trotzdem sofort gebucht
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

ecbXml = [[
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
LocalStorage       = {}

-- Simulierte MoneyMoney-Datenbank: gebuchte Umsätze nach transactionId, wie sie
-- isKnownTransactionId nachschlägt
local mmdb = {}
local function isKnown (id) return mmdb[id] end

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

local function sumDb ()
  local sum = 0
  for _, t in pairs(mmdb) do sum = sum + t.amount end
  return round(sum)
end

local function expenseById (id)
  for _, e in ipairs(fixtures.expenses.expenses) do
    if e.id == id then return e end
  end
end

local function contains (s, needle)
  return string.find(tostring(s), needle, 1, true) ~= nil
end

-- Umsatz anhand des Namens (= Splitwise-Beschreibung) und optional des
-- Buchungstexts finden
local function byName (transactions, name, bookingText)
  for _, t in ipairs(transactions) do
    if t.name == name
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

-- Abruf wie MoneyMoney: gelieferte Umsätze landen in der simulierten Datenbank
local function refresh (withKnown)
  local r = RefreshAccount(accounts[1], 0, withKnown ~= false and isKnown or nil)
  if type(r) == 'table' then
    for _, t in ipairs(r.transactions) do
      if t.transactionId then mmdb[t.transactionId] = t end
    end
  end
  return r
end

local result = refresh()
local tx = result.transactions

-- Saldo aus get_friends: 12,50 − 7,25 + 20 USD / 1,08 = 23,77 (ohne Abzug, da
-- nichts mehr vorgemerkt ist)
check('Saldo = Splitwise-Gesamtsaldo', result.balance, 23.77)
check('kein pendingBalance mehr', result.pendingBalance, nil)
local allBooked = true
for _, t in ipairs(tx) do
  if t.booked ~= true then allBooked = false end
end
check('alle Umsätze gebucht', allBooked, true)
check('ganze Historie abgefragt', contains(requests[#requests - 1].url, 'get_expenses?limit=0')
  or contains(requests[#requests].url, 'get_expenses?limit=0'), true)

check('elf Umsätze (gelöscht, fremd ausgelassen; selbst bezahlte doppelt)', #tx, 11)
check('gelöschte Ausgabe fehlt', byName(tx, 'Gelöscht'), nil)
check('fremde Ausgabe fehlt', byName(tx, 'Fremd'), nil)

local oil = byName(tx, 'Olivenöl')
check('andere zahlen: minus dein Anteil', oil and oil.amount, -18)
check('Kategorie als Buchungstext', oil and oil.bookingText, 'Lebensmittel')
check('andere zahlen: Zweck = Gruppe · Zahler · Gesamt', oil and oil.purpose,
  'Sizilien · bezahlt von Anna Alpha · Gesamt 72,00 EUR')
check('Zweck einzeilig', contains(oil and oil.purpose, '\n'), false)
check('Kennung Anteil', oil and oil.transactionId, 'sw:101:anteil')
check('Umsatzwährung = Kontowährung', oil and oil.currency, 'EUR')
check('andere zahlen: keine Zahlung', byName(tx, 'Olivenöl', 'Zahlung'), nil)

-- Du zahlst 1.234,50, ihr teilt 50/50: Ausgabe −617,25 + Zahlung +1.234,50 = +617,25
local dinner = byName(tx, 'Restaurant', 'Restaurant')
local dinnerPay = byName(tx, 'Restaurant', 'Zahlung')
check('du zahlst: Ausgabe = minus dein Anteil', dinner and dinner.amount, -617.25)
check('du zahlst: Ausgabe mit Kategorie', dinner and dinner.bookingText, 'Restaurant')
check('du zahlst: Anteil-Zweck (ohne Gruppe, Tausenderpunkt)', dinner and dinner.purpose,
  'dein Anteil · Gesamt 1.234,50 EUR, bezahlt von dir')
check('du zahlst: Zahlung = gezahlter Betrag', dinnerPay and dinnerPay.amount, 1234.5)
check('Kennung Zahlung', dinnerPay and dinnerPay.transactionId, 'sw:102:zahlung')
check('Zahlung: Zweck nennt, mit wem geteilt', dinnerPay and dinnerPay.purpose,
  'deine Zahlung · geteilt mit Ben')
check('Ausgabe + Zahlung = Saldoänderung', dinner.amount + dinnerPay.amount, 617.25)
check('Buchungsdatum UTC (2024-02-29 12:00Z)', dinner and dinner.bookingDate, 1709208000)
check('Zahlung gleiches Datum', dinnerPay and dinnerPay.bookingDate, 1709208000)

-- Genau deinen Anteil bezahlt: Saldo unverändert, Ausgabe trotzdem sichtbar
local neutral = byName(tx, 'Neutral', 'Ausgabe')
local neutralPay = byName(tx, 'Neutral', 'Zahlung')
check('eigener Anteil selbst bezahlt: Ausgabe −5', neutral and neutral.amount, -5)
check('eigener Anteil selbst bezahlt: Zahlung +5', neutralPay and neutralPay.amount, 5)
check('mehrere Zahler im Zweck', contains(neutral and neutral.purpose, 'bezahlt von dir und Anna Alpha'), true)

-- Anteil 0 (Vorschuss): nur die Zahlung, keine 0-€-Ausgabe
check('Anteil 0: keine Ausgabe', byName(tx, 'Abschlag', 'Allgemein'), nil)
local advance = byName(tx, 'Abschlag', 'Zahlung')
check('Anteil 0: Zahlung +240', advance and advance.amount, 240)

local fromAnna = byName(tx, 'Ausgleich von Anna Alpha')
check('Zahlung erhalten: negativ', fromAnna and fromAnna.amount, -30)
check('Zahlung: Buchungstext', fromAnna and fromAnna.bookingText, 'Ausgleichszahlung')
check('Kennung Ausgleichszahlung', fromAnna and fromAnna.transactionId, 'sw:103:ausgleich')

local toBen = byName(tx, 'Ausgleich an Ben')
check('Zahlung geleistet: positiv', toBen and toBen.amount, 7.25)
check('Ausgleich: Zweck', toBen and toBen.purpose, 'Ausgleichszahlung')

local usd = byName(tx, 'Diner')
check('USD in EUR umgerechnet (−20 / 1,08)', round(usd and usd.amount), -18.52)
check('USD: Originalbetrag im Zweck', contains(usd and usd.purpose, 'Originalbetrag -20,00 USD'), true)

local taxi = byName(tx, 'Taxi')
check('frische Ausgabe sofort gebucht', taxi and taxi.booked, true)

local market = byName(tx, 'Markt')
check('unbekannter Kurs: Betrag 0', market and market.amount, 0)
check('unbekannter Kurs: Hinweis im Zweck', contains(market and market.purpose, 'kein EZB-Kurs'), true)

-- Summe aller Umsätze: −18 + 617,25 − 30 + 7,25 + 0 − 18,52 − 10 + 240 + 0
check('Summe in MoneyMoney nach erstem Abruf', sumDb(), 787.98)

-- --------------------------------------------------------------------------
-- Änderungen in Splitwise → Korrekturbuchungen
-- --------------------------------------------------------------------------

check('zweiter Abruf ohne Änderung: keine Umsätze', #refresh().transactions, 0)

-- Neuer EZB-Kurs: bereits gebuchte Fremdwährung bleibt, keine Korrektur
InitializeSession(ProtocolWebBanking, 'Splitwise', KEY, '', '')
local oldEcb = ecbXml
ecbXml = string.gsub(ecbXml, '1%.0800', '1.2500')
check('neuer Wechselkurs: keine Korrektur', #refresh().transactions, 0)
ecbXml = oldEcb
InitializeSession(ProtocolWebBanking, 'Splitwise', KEY, '', '')

-- Olivenöl: dein Anteil 18 → 15; Taxi gelöscht; Abschlag jetzt von Ben bezahlt
local oilE = expenseById(101)
oilE.users = { share(1, anna, '72.0', '21.0'), share(ME, self, '0.0', '15.0'),
               share(2, ben, '0.0', '36.0') }
oilE.updated_at = '2026-11-20T08:00:00Z'
local taxiE = expenseById(109)
taxiE.deleted_at = '2026-11-21T09:00:00Z'
local advE = expenseById(111)
advE.users = { share(2, ben, '240.0', '240.0'), share(ME, self, '0.0', '0.0') }
advE.updated_at = '2026-11-20T08:00:00Z'

local changes = refresh().transactions
check('drei Korrekturen', #changes, 3)

local oilK = byName(changes, 'Olivenöl')
check('Korrektur: Differenz +3', oilK and oilK.amount, 3)
check('Korrektur: Zweck beginnt mit Gruppe · Korrektur 1', contains(oilK and oilK.purpose,
  'Sizilien · Korrektur 1 · in Splitwise geändert'), true)
check('Korrektur: Kategorie wie Original', oilK and oilK.bookingText, 'Lebensmittel')
check('Korrektur: gebucht', oilK and oilK.booked, true)
check('Korrektur: Kennung', oilK and oilK.transactionId, 'sw:101:anteil:k1')
check('Korrektur: Datum = Änderung in Splitwise', oilK and oilK.bookingDate, 1795161600)
check('Korrektur: vorher/jetzt im Zweck', contains(oilK and oilK.purpose,
  'vorher -18,00 EUR, jetzt -15,00 EUR'), true)
check('Korrektur: Datum der Ausgabe im Zweck', contains(oilK and oilK.purpose, 'Ausgabe vom 10.03.2025'), true)

local taxiS = byName(changes, 'Taxi')
check('Storno: Gegenbuchung +10', taxiS and taxiS.amount, 10)
check('Storno: Kategorie wie Original', taxiS and taxiS.bookingText, 'Taxi')
check('Storno: Zweck', contains(taxiS and taxiS.purpose,
  'Storno (Korrektur 1) · in Splitwise gelöscht'), true)
check('Storno: Datum = Löschung', taxiS and taxiS.bookingDate, 1795251600)
check('Storno: Kennung', taxiS and taxiS.transactionId, 'sw:109:anteil:k1')

local advK = byName(changes, 'Abschlag')
check('Rolle entfällt: Korrektur −240', advK and advK.amount, -240)
check('Rolle entfällt: Buchungstext Zahlung', advK and advK.bookingText, 'Zahlung')
check('Rolle entfällt: jetzt 0', contains(advK and advK.purpose, 'jetzt 0,00 EUR'), true)

-- 787,98 + 3 + 10 − 240
check('Summe nach Korrekturen', sumDb(), 560.98)
check('nach Korrektur: nächster Abruf ohne Umsätze', #refresh().transactions, 0)

-- Zweite Änderung derselben Ausgabe → zweite Korrektur
oilE.users[2] = share(ME, self, '0.0', '12.0')
local again = refresh().transactions
check('zweite Änderung: eine Korrektur', #again, 1)
check('zweite Änderung: Kennung k2', again[1] and again[1].transactionId, 'sw:101:anteil:k2')
check('zweite Änderung: vorher -15', contains(again[1] and again[1].purpose,
  'vorher -15,00 EUR, jetzt -12,00 EUR'), true)

-- LocalStorage leer (Bankzugang neu eingerichtet), MoneyMoney hat alles:
-- Stand wird über isKnownTransactionId rekonstruiert, nichts doppelt
LocalStorage = {}
check('Speicher leer: nichts doppelt', #refresh().transactions, 0)
oilE.users[2] = share(ME, self, '0.0', '10.0')
local afterReset = refresh().transactions
check('Speicher leer: Korrektur zählt weiter (k3)', afterReset[1] and afterReset[1].transactionId,
  'sw:101:anteil:k3')
check('Speicher leer: Differenz aus MoneyMoney-Stand', afterReset[1] and afterReset[1].amount, 2)
-- 560,98 + 3 + 2
check('Summe nach Rekonstruktion', sumDb(), 565.98)

-- Ohne isKnownTransactionId: nur LocalStorage, ebenfalls nichts doppelt
check('ohne isKnownTransactionId: nichts doppelt', #refresh(false).transactions, 0)

-- Konto in MoneyMoney neu angelegt, LocalStorage noch voll: alles neu, ohne Korrekturen
mmdb = {}
local fresh = refresh().transactions
local hasCorrection = false
for _, t in ipairs(fresh) do
  if contains(t.purpose, 'Korrektur') or contains(t.purpose, 'Storno') then hasCorrection = true end
end
check('neues Konto: neun Umsätze', #fresh, 9)
check('neues Konto: keine Korrekturen', hasCorrection, false)
check('neues Konto: Summe = aktueller Stand', sumDb(), 565.98)
local freshOil = byName(fresh, 'Olivenöl')
check('neues Konto: Olivenöl mit aktuellem Anteil', freshOil and freshOil.amount, -10)

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
