# moneymoney-splitwise

Eine [MoneyMoney](https://moneymoney.app/)-WebBanking-Extension für **Splitwise**. Splitwise
erscheint in MoneyMoney als Konto mit Umsätzen: je Ausgabe ein Umsatz mit dem Datum der
Ausgabe. Der Kontosaldo ist dein offener Betrag über alle Freunde, also derselbe Wert wie in
der Splitwise-App.

Neufassung von [slauber/moneymoney-splitwise](https://github.com/slauber/moneymoney-splitwise)
(2022). Die API-Aufrufe sind dieselben, behoben bzw. ergänzt wurden:

| Problem in der Version von 2022 | Jetzt |
|---|---|
| Depot mit einer Position je Freund: zeigt, wem du etwas schuldest, aber nicht wofür | Konto mit einem Umsatz je Ausgabe, Kategorie und Gruppe im Verwendungszweck |
| Fremdwährungen landeten über das nicht existierende Feld `currency` ungerechnet als Kontowährung im Depot | Umrechnung in die Kontowährung über die EZB-Tageskurse, Originalbetrag im Verwendungszweck |
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

Je Ausgabe, an der du beteiligt bist, ein oder zwei Umsätze mit dem Datum der Ausgabe:

| Fall | Umsätze | Gegenpartei |
|---|---|---|
| Jemand anderes hat bezahlt | minus dein Anteil (Ausgabe) | wer bezahlt hat |
| Du hast bezahlt | minus dein Anteil (Ausgabe) **und** plus dein gezahlter Betrag (Zahlung) | „Du" |
| Ausgleichszahlung | Zahlbetrag (erhalten: minus, geleistet: plus) | der andere |

Beispiel: Du zahlst 100 € mit Karte, ihr teilt 50/50.

- Bankkonto: −100 €.
- Splitwise-Konto: **−50 €** Ausgabe (Kategorie z. B. Restaurant) und **+100 €** „Zahlung".

Die Zahlung ist das Gegenstück zur Abbuchung auf dem Bankkonto (gleicher Betrag, z. B. als
Umbuchung kategorisieren). Die Ausgabe zeigt, was du selbst ausgegeben hast. In Splitwise
bleiben +50 €: der andere schuldet dir die Hälfte. Die Summe aller Umsätze ist genau dein
Splitwise-Saldo.

- Buchungstext = Splitwise-Kategorie (z. B. „Restaurant", „Lebensmittel"), „Zahlung" oder
  „Ausgleichszahlung"; damit lassen sich in MoneyMoney Kategorieregeln anlegen.
- Verwendungszweck: Beschreibung, Gesamtbetrag, wer bezahlt hat, dein Anteil, Gruppe.
- Hast du bezahlt, aber keinen Anteil (Vorschuss für andere), gibt es nur die Zahlung.
- Gelöschte Ausgaben und Ausgaben ohne dich werden ausgelassen. Abgerufen wird immer die ganze Historie.
- Ausgaben der letzten 14 Tage kommen als *vorgemerkt*. MoneyMoney ersetzt vorgemerkte Umsätze
  bei jedem Abruf, sodass Änderungen in Splitwise keine Dubletten erzeugen. Wie bei einer
  Bank zeigt MoneyMoney oben den gebuchten Saldo und darunter „Vorgemerkt"; beides zusammen
  ist dein Splitwise-Saldo. Änderst du eine
  ältere Ausgabe, erscheint sie neu und die alte Fassung muss in MoneyMoney von Hand gelöscht
  werden (MoneyMoney kennt keine Umsatz-IDs für Extensions).
- Fremdwährungen werden mit dem EZB-Referenzkurs vom Abruftag in die Kontowährung
  umgerechnet; der Originalbetrag steht im Verwendungszweck. Ohne EZB-Kurs (exotische Währung)
  ist der Betrag 0 mit Hinweis im Verwendungszweck.

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

Ein bestehendes Splitwise-**Depot** (alte Extension oder frühere Version dieser) lässt sich
nicht in ein Konto mit Umsätzen umwandeln: das Depot in MoneyMoney löschen und das Konto neu
hinzufügen.

## API-Details

- Basis: `https://secure.splitwise.com/api/v3.0/`, Header `Authorization: Bearer <API-Key>`.
- `GET get_current_user` → `user.id`, `first_name`, `last_name`, `default_currency`.
- `GET get_friends` → `friends[].balance[] = { currency_code, amount }`, `amount` als String;
  Summe = Kontosaldo.
- `GET get_expenses?limit=0` → alle Ausgaben; je Ausgabe `users[] = { user_id, paid_share,
  owed_share, net_balance }`. Dein `net_balance` ist der Umsatzbetrag. `payment = true` markiert
  Ausgleichszahlungen, `deleted_at` gelöschte Ausgaben.
- `GET get_groups` → Gruppennamen für den Verwendungszweck.
- Fehlerformen: `{"error": "…"}` (401) und `{"errors": {"base": ["…"]}}` (403 u. a.).
- Kurse: `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`, nur abgerufen, wenn
  ein Saldo oder eine Ausgabe in Fremdwährung vorkommt.

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
