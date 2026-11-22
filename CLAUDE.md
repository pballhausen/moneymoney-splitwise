# moneymoney-splitwise — Kontext für Claude Code

MoneyMoney-WebBanking-Extension (Lua), die Splitwise als Konto mit Umsätzen abruft: je Ausgabe
ein oder zwei Umsätze, Saldo = offene Beträge über alle Freunde. Neufassung von
github.com/slauber/moneymoney-splitwise (2022, MIT). Aufbau analog zu ../moneymoney-become1.

## Stand (18.11.2026)
- Konto (`AccountTypeOther`) statt Depot — Wunsch des Nutzers: in MoneyMoney zählt, wofür das
  Geld ausgegeben wurde, nicht wem man es schuldet.
- Umsätze je Ausgabe, Summe immer = eigenes `net_balance` (paid − owed):
  andere zahlen → ein Umsatz −owed_share (Name = Zahler, Buchungstext = Kategorie);
  ich zahle → ZWEI Umsätze: −owed_share (Kategorie) und +paid_share ("Zahlung", Name "Du"),
  Wunsch des Nutzers: Zahlung matcht die Bankabbuchung, Anteil ist kategorisierbare Ausgabe
  (vorher ein Umsatz +net → wirkte wie Einnahme). Anteil 0 → nur Zahlung.
  Ausgleichszahlung (payment=true) → ein Umsatz über net_balance.
- Saldo aus get_friends, Umsätze aus `get_expenses?limit=0` (ganze Historie), Gruppennamen aus
  get_groups. Buchungstext = Splitwise-Kategorie. Ausgaben < 7 Tage (bis 22.11.2026: 14) → booked=false gegen
  Dubletten bei Änderungen. Datum per eigener UTC-Umrechnung (parseIsoUtc).
- `balance` = Splitwise-Saldo MINUS vorgemerkte Umsätze: MoneyMoney zählt Vorgemerktes selbst
  dazu. Erste Version lieferte den Gesamtsaldo → Startsaldo im Konto −18 statt 0, alle
  Tagessalden verschoben (vom Nutzer im Screenshot entdeckt, 18.11.2026).
- Zusätzlich `pendingBalance` = Summe der vorgemerkten Umsätze (22.11.2026), damit die
  Seitenleiste den Gesamtsaldo zeigen kann. Ob MoneyMoney das Feld dort einrechnet, ist
  laut API-Doku offen → offener Punkt 3.
- Fremdwährung: Umrechnung per EZB-Tageskurs, Original im Verwendungszweck; ohne Kurs Betrag 0.
- Fehlerbehandlung: Accept JSON, 401 → LoginFailed, 403 ohne Pro → Klartext.
  API-Key aus username ODER password (erstes Feld ≥30 Zeichen ohne Leerzeichen).
  accountNumber weiter "email (id)".
- Offline-Tests: `lua test/run_tests.lua` (60 Tests, grün).
- Live (18.11.2026, curl-Harness): 152 Umsätze, Summe −261,16 EUR = Saldo aus get_friends;
  gebuchte Summe −243,16 = gelieferter balance → Startsaldo 0.
  Kein 403, Pro-Sperre greift beim eigenen Key nicht. Eigene Ausgaben alle in EUR.
- Installation in MoneyMoney muss der Nutzer per Finder machen: macOS sperrt den
  MoneyMoney-Container für andere Apps (cp → "Operation not permitted").
- Git: öffentliches Repo https://github.com/pballhausen/moneymoney-splitwise.

## Offene Punkte
1. (erledigt 18.11.2026) Umsatzkonto in MoneyMoney vom Nutzer geprüft: Saldo, Startsaldo und
   Aufteilung Anteil/Zahlung passen. Hinweis: Änderungen am Umsatzmodell erfordern, das Konto
   in MoneyMoney zu löschen und neu anzulegen (gebuchte Umsätze bleiben sonst stehen).
2. Fremdwährungsausgaben live prüfen, sobald es welche mit Beteiligung des Nutzers gibt.
3. In MoneyMoney prüfen, ob die Seitenleiste mit `pendingBalance` den Saldo inkl.
   Vorgemerktem zeigt. Falls nicht: Feld schadet nicht, Alternativen (alles gebucht melden /
   vollen Saldo als balance) haben Dubletten bzw. falschen Startsaldo zur Folge.

## Regeln
- Den API-Key nie committen (`.env` ist ignoriert).
- MoneyMoney-API-Doku: https://moneymoney.app/api/webbanking/
- Splitwise-API: https://dev.splitwise.com/ (Basis https://secure.splitwise.com/api/v3.0/, Bearer-Key)
