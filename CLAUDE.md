# moneymoney-splitwise — Kontext für Claude Code

MoneyMoney-WebBanking-Extension (Lua), die Splitwise-Salden je Freund und Währung als Depot
abruft. Neufassung von github.com/slauber/moneymoney-splitwise (2022, MIT). Aufbau analog zu
../moneymoney-become1.

## Stand (18.11.2026)
- `Splitwise.lua` neu geschrieben: Accept-JSON-Fehlerbehandlung, LoginFailed bei 401, klare
  Meldung bei 403 ohne Splitwise Pro, Beträge als Zahl, Fremdwährungen über
  originalAmount/currencyOfOriginalAmount + EZB-Kurs, Kontowährung = default_currency,
  accountNumber im alten Format "email (id)" für Kompatibilität mit bestehenden Konten.
- API-Key wird aus username ODER password gelesen (erstes Feld, das wie ein Key aussieht, ≥30 Zeichen).
- Offline-Tests: `lua test/run_tests.lua` (28 Tests, grün).
- Live-API getestet (18.11.2026): get_current_user und get_friends liefern HTTP 200 — kein
  403, Pro-Sperre greift beim eigenen Key also nicht. Extension mit curl-Harness end-to-end
  gelaufen: Login per Key in username und password ok, falscher Key → LoginFailed, Konto in
  EUR, Kontonummer "email (id)", eine Position (EUR, Zahl). EZB-XML wird korrekt geparst
  (29 Kurse). Fremdwährungspfad live noch ungetestet (aktuell keine Fremdwährungssalden).
- Git: `git init` + origin gesetzt, noch kein Commit, GitHub-Repo existiert noch nicht.

## Offene Punkte
1. (erledigt) Live-Test gegen die API.
2. (erledigt 18.11.2026) Extension in MoneyMoney installiert, Konto angelegt, Abruf läuft,
   EUR-Position wird angezeigt. Installation muss der Nutzer per Finder machen: macOS sperrt
   den MoneyMoney-Container für andere Apps (cp → "Operation not permitted").
   Offen: Darstellung von Fremdwährungspositionen (`amount` + `originalAmount`) prüfen, sobald
   ein Saldo in Fremdwährung existiert.
3. Erster Commit, Repo auf GitHub anlegen.

## Regeln
- Den API-Key nie committen (`.env` ist ignoriert).
- MoneyMoney-API-Doku: https://moneymoney.app/api/webbanking/
- Splitwise-API: https://dev.splitwise.com/ (Basis https://secure.splitwise.com/api/v3.0/, Bearer-Key)
