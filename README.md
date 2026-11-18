# moneymoney-splitwise

Eine [MoneyMoney](https://moneymoney.app/)-WebBanking-Extension, die die offenen Salden mit
deinen **Splitwise**-Freunden abruft. Splitwise erscheint damit als Depot in MoneyMoney: je
Freund und Währung eine Position.

Neufassung von [slauber/moneymoney-splitwise](https://github.com/slauber/moneymoney-splitwise)
(2022). Die API-Aufrufe sind dieselben, behoben bzw. ergänzt wurden:

| Problem in der Version von 2022 | Jetzt |
|---|---|
| Fremdwährungen landeten über das nicht existierende Feld `currency` ungerechnet als Kontowährung im Depot | `originalAmount`/`currencyOfOriginalAmount` plus Umrechnung in die Kontowährung über die EZB-Tageskurse |
| Beträge als String übergeben | als Zahl |
| HTTP-Fehler brachen ohne Erklärung ab („Forbidden") | `Accept: application/json`, Splitwise-Fehlertext wird angezeigt |
| Falscher Key → generischer Fehler, MoneyMoney versucht es weiter | `LoginFailed`, MoneyMoney pausiert den Abruf bis zur Korrektur |
| Kein Hinweis auf die Pro-Pflicht | eigene, verständliche Meldung bei HTTP 403 |
| API-Pfad aus der Extension-Versionsnummer gebaut (`version = "3.0"`) | fester API-Pfad, `version` ist eine Zahl wie von MoneyMoney verlangt |
| Kontowährung fest | Standardwährung deines Splitwise-Kontos |

## Wichtig: Splitwise Pro erforderlich

Seit etwa Herbst 2026 lässt Splitwise API-Zugriffe nur noch zu, wenn das Konto, das die
API-App registriert hat, ein **aktives Splitwise Pro** hat. Ohne Pro antwortet jeder Aufruf mit
HTTP 403 („Diese App kann derzeit nicht auf Splitwise zugreifen, da ihr Entwickler kein aktives
Splitwise Pro-Abonnement hat …"). Da jeder Nutzer dieser Extension seine eigene App registriert,
betrifft das jeden. Siehe
[Issue #1 im Original-Repo](https://github.com/slauber/moneymoney-splitwise/issues/1) und den
Vorbehalt in den [API-Bedingungen](https://dev.splitwise.com/).

Die Extension kann daran nichts ändern; sie meldet den Fall nur im Klartext.

## Funktionen

- Je Freund und Währung eine Depotposition mit dem offenen Saldo.
  Positiv = der Freund schuldet dir etwas, negativ = du schuldest ihm etwas.
- Ausgeglichene Freunde werden ausgelassen.
- Salden in Fremdwährung werden mit dem EZB-Referenzkurs in die Kontowährung umgerechnet; der
  Originalbetrag bleibt sichtbar. Gibt es für eine Währung keinen EZB-Kurs, bleibt der Wert in
  Kontowährung leer, statt einen falschen Betrag zu zeigen.
- Der Saldo pro Freund ist der Gesamtsaldo über alle Gruppen (wie in der Splitwise-App unter
  „Freunde"). Einzelne Ausgaben werden nicht abgerufen.

## Installation

1. [`Splitwise.lua`](Splitwise.lua) in den MoneyMoney-Extensions-Ordner kopieren:

   ```
   ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions/
   ```

   Alternativ in MoneyMoney: **Hilfe → Datenbank im Finder zeigen** → Ordner `Extensions`.
   Eine ältere `Splitwise.lua` dort ersetzen.

2. Die Neufassung ist nicht signiert. In **Einstellungen → Erweiterungen** die Option
   „Digitale Signatur von Extensions überprüfen" ausschalten.

3. MoneyMoney neu starten.

## API-Key besorgen

1. Auf <https://secure.splitwise.com/apps> einloggen.
2. **Register your application** — Name und Beschreibung beliebig, als Homepage-URL reicht z. B.
   `https://moneymoney.app`.
3. Auf der Detailseite der App **Generate API key** klicken und den Key (40 Zeichen) kopieren.

Der Key ist ein vollwertiges Zugangsmerkmal zu deinem Splitwise-Konto — behandle ihn wie ein
Passwort. Auf derselben Seite lässt er sich jederzeit neu erzeugen, der alte wird dann ungültig.

## Einrichtung in MoneyMoney

1. **Konto hinzufügen** → Dienst **Splitwise** wählen.
2. Den API-Key in das erste Feld eintragen (MoneyMoney beschriftet es für Splitwise als
   API-Key bzw. Benutzername). Verlangt MoneyMoney zusätzlich ein Passwort, etwas Beliebiges
   eintragen, z. B. `dummy`. Steht der Key im Passwortfeld, wird er ebenfalls erkannt.

Bestehende Konten aus der alten Extension funktionieren weiter; sie müssen nicht neu angelegt
werden.

## API-Details

- Basis: `https://secure.splitwise.com/api/v3.0/`, Header `Authorization: Bearer <API-Key>`.
- `GET get_current_user` → `user.id`, `first_name`, `last_name`, `default_currency`.
- `GET get_friends` → `friends[].balance[] = { currency_code, amount }`, `amount` als String.
- Fehlerformen: `{"error": "…"}` (401) und `{"errors": {"base": ["…"]}}` (403 u. a.).
- Kurse: `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`, nur abgerufen, wenn
  ein Saldo in Fremdwährung vorkommt.

## Entwicklung

Offline-Tests gegen Fixtures (stubben `WebBanking`, `Connection` und `JSON`):

```bash
lua test/run_tests.lua
```

Die API direkt per curl erkunden:

```bash
cp .env.example .env     # SPLITWISE_API_KEY eintragen
./explore.sh get_current_user
./explore.sh get_friends
```

Die `.env` ist über [`.gitignore`](.gitignore) ausgeschlossen.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Basiert auf der Extension von Sebastian Lauber.
