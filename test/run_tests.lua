-- Offline-Test für Splitwise.lua.
--
-- Stubt die MoneyMoney-Laufzeit (WebBanking, Connection, JSON, Konstanten) und
-- fährt InitializeSession → ListAccounts → RefreshAccount gegen feste Fixtures.
-- Geprüft werden Key-Erkennung, Fehlerbehandlung (401, 403 ohne Pro),
-- Betragsumwandlung und Fremdwährungen — nicht die Netzwerkschicht.
--
-- Ausführen:  lua test/run_tests.lua

-- --------------------------------------------------------------------------
-- Fixtures (Struktur wie von secure.splitwise.com/api/v3.0 dokumentiert)
-- --------------------------------------------------------------------------

local KEY = 'abcdefghijklmnopqrstuvwxyz0123456789ABCD'   -- 40 Zeichen

local fixtures = {
  user = {
    user = { id = 4711, first_name = 'Philipp', last_name = 'Test',
             email = 'philipp@example.com', default_currency = 'EUR' }
  },

  friends = {
    friends = {
      { id = 1, first_name = 'Anna', last_name = 'Alpha',
        balance = { { currency_code = 'EUR', amount = '12.5' } } },
      { id = 2, first_name = 'Ben', last_name = nil,
        balance = { { currency_code = 'EUR', amount = '-7.25' },
                    { currency_code = 'USD', amount = '20.0' } } },
      { id = 3, first_name = 'Carla', last_name = 'Ausgeglichen', balance = {} },
      { id = 4, first_name = 'Dora', last_name = 'Null',
        balance = { { currency_code = 'EUR', amount = '0.0' } } },
      { id = 5, first_name = 'Emil', last_name = 'Exot',
        balance = { { currency_code = 'XAF', amount = '1000' } } }
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

ProtocolWebBanking   = 'ProtocolWebBanking'
AccountTypePortfolio = 'AccountTypePortfolio'
LoginFailed          = 'LoginFailed'

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

local function byName (securities, name)
  for _, s in ipairs(securities) do
    if s.name == name then return s end
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
check('Kontotyp Depot', accounts[1].type, AccountTypePortfolio)
check('portfolio = true', accounts[1].portfolio, true)
check('Kontonummer wie alte Extension', accounts[1].accountNumber, 'philipp@example.com (4711)')
check('Kontowährung = default_currency', accounts[1].currency, 'EUR')
check('Inhaber', accounts[1].owner, 'Philipp Test')

local result = RefreshAccount(accounts[1], 0)
local sec = result.securities

check('vier Positionen (ausgeglichene ausgelassen)', #sec, 4)
check('Anna: Betrag als Zahl', byName(sec, 'Anna Alpha') and byName(sec, 'Anna Alpha').amount, 12.5)
check('Ben EUR: negativ, mit Währungssuffix (mehrere Währungen)',
  byName(sec, 'Ben (EUR)') and byName(sec, 'Ben (EUR)').amount, -7.25)

local benUsd = byName(sec, 'Ben (USD)')
check('Ben USD: originalAmount', benUsd and benUsd.originalAmount, 20)
check('Ben USD: Originalwährung', benUsd and benUsd.currencyOfOriginalAmount, 'USD')
check('Ben USD: in EUR umgerechnet (20 / 1,08)', round(benUsd and benUsd.amount), 18.52)

local emil = byName(sec, 'Emil Exot (XAF)')
check('unbekannter Kurs: kein amount', emil and emil.amount, nil)
check('unbekannter Kurs: originalAmount bleibt', emil and emil.originalAmount, 1000)

-- 401: abgelaufener/falscher Key → LoginFailed (MoneyMoney pausiert dann den Abruf)
scenario = 'unauthorized'
check('401 → LoginFailed', InitializeSession(ProtocolWebBanking, 'Splitwise', KEY, '', ''), LoginFailed)

-- 403 ohne Pro → verständliche Meldung, kein LoginFailed
scenario = 'noPro'
local msg = InitializeSession(ProtocolWebBanking, 'Splitwise', KEY, '', '')
check('403 ohne Pro: kein LoginFailed', msg ~= LoginFailed, true)
check('403 ohne Pro: Meldung nennt Splitwise Pro', contains(msg, 'Splitwise Pro'), true)

-- Fehler beim Abruf der Freunde wird gemeldet, nicht still als leeres Depot
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
