# moneymoney-splitwise — Kontext für Claude Code

MoneyMoney-WebBanking-Extension (Lua), die Splitwise als Konto mit Umsätzen abruft: je Ausgabe
ein oder zwei Umsätze, Saldo = offene Beträge über alle Freunde. Neufassung von
github.com/slauber/moneymoney-splitwise (2022, MIT). Aufbau analog zu ../moneymoney-become1.

## Stand (22.11.2026)
- Konto (`AccountTypeOther`) statt Depot — Wunsch des Nutzers: in MoneyMoney zählt, wofür das
  Geld ausgegeben wurde, nicht wem man es schuldet.
- Umsätze je Ausgabe, Summe immer = eigenes `net_balance` (paid − owed):
  andere zahlen → ein Umsatz −owed_share (Buchungstext = Kategorie);
  ich zahle → ZWEI Umsätze: −owed_share (Kategorie) und +paid_share (Buchungstext "Zahlung"),
  Wunsch des Nutzers: Zahlung matcht die Bankabbuchung, Anteil ist kategorisierbare Ausgabe
  (vorher ein Umsatz +net → wirkte wie Einnahme). Anteil 0 → nur Zahlung.
  Ausgleichszahlung (payment=true) → ein Umsatz über net_balance.
- Saldo aus get_friends, Umsätze aus `get_expenses?limit=0` (ganze Historie), Gruppennamen aus
  get_groups. Buchungstext = Splitwise-Kategorie. Datum per eigener UTC-Umrechnung (parseIsoUtc).
- Darstellung (seit 23.11.2026, Wunsch des Nutzers: fette Zeile soll sagen, WOFÜR):
  Name = Splitwise-Beschreibung; Zweck einzeilig, Wichtigstes vorn (MoneyMoney kürzt hinten):
  "Gruppe · bezahlt von X · Gesamt …" bzw. "Gruppe · dein Anteil · Gesamt …, bezahlt von dir"
  bzw. "Gruppe · deine Zahlung · geteilt mit …". Ausgleich: Name "Ausgleich an/von X".
  Korrekturen: gleicher Name, Zweck "Gruppe · Korrektur <n> · …" / "Storno (Korrektur <n>) · …".
  Vorher: Name = Zahler bzw. "Du", Beschreibung im Zweck.
- ALLES sofort gebucht (seit 22.11.2026), balance = voller Splitwise-Saldo. Grund: Nutzer will
  den Gesamtsaldo in der Seitenleiste; die zeigt nur den gebuchten Saldo. Gescheitert (vom
  Nutzer in MoneyMoney geprüft): pendingBalance als Summe der vorgemerkten, pendingBalance als
  Gesamtsaldo (wie Become1), Kontotyp Kreditkarte (wie Become1). Vorher: Ausgaben < 14/7 Tage
  vorgemerkt, balance = Saldo minus Vorgemerktes (sonst Startsaldo falsch).
- Änderungen → Korrekturbuchungen: transactionId "sw:<expenseId>:<anteil|zahlung|ausgleich>",
  Korrekturen ":k<n>". Gebuchter Stand je Ausgabe/Rolle in LocalStorage.expenses (Wert in
  Ausgabewährung, Betrag in Kontowährung, Anzahl Korrekturen, Name/Kategorie). Abgleich über
  isKnownTransactionId (3. Parameter von RefreshAccount): unbekannt → als neu liefern (Konto neu
  angelegt); LocalStorage leer → Stand aus Original + Korrekturen rekonstruieren. Gelöscht
  (deleted_at, kommt in get_expenses mit) → Storno; Rolle entfällt → Korrektur auf 0. Ausgaben,
  die ganz aus der Antwort fehlen, bleiben unangetastet (Schutz vor API-Aussetzern).
  MoneyMoney-Dublettenerkennung läuft nur über Buchungstag, Betrag, Name, Zweck — deshalb
  "Korrektur <n>" im Zweck. Nur Text/Kategorie/Datum geändert → keine Korrektur.
- Kursänderungen erzeugen keine Korrektur (Vergleich in Ausgabewährung); balance aus get_friends
  nutzt den Tageskurs → bei Fremdwährung leichte Abweichung Saldo/Umsatzsumme möglich.
- Fremdwährung: Umrechnung per EZB-Kurs vom Tag der ersten Buchung, Original im
  Verwendungszweck; ohne Kurs Betrag 0.
- Fehlerbehandlung: Accept JSON, 401 → LoginFailed, 403 ohne Pro → Klartext.
  API-Key aus username ODER password (erstes Feld ≥30 Zeichen ohne Leerzeichen).
  accountNumber weiter "email (id)".
- Offline-Tests: `lua test/run_tests.lua` (92 Tests, grün, inkl. Korrekturen/Storno/Rekonstruktion).
- Live (23.11.2026, neue Darstellung): 167 Umsätze, Summe −360,86 EUR = balance; zweiter Abruf
  und Abruf mit leerem LocalStorage liefern 0 Umsätze.
- Live (22.11.2026, curl-Harness): 159 Umsätze, Summe −337,06 EUR = balance → Startsaldo 0;
  zweiter Abruf und Abruf mit leerem LocalStorage liefern 0 Umsätze. 183 Ausgaben, davon 3
  gelöscht, 32 nachträglich geändert (updated_at > created_at).
  Kein 403, Pro-Sperre greift beim eigenen Key nicht. Eigene Ausgaben alle in EUR.
- Installation in MoneyMoney muss der Nutzer per Finder machen: macOS sperrt den
  MoneyMoney-Container für andere Apps (cp → "Operation not permitted").
- Git: öffentliches Repo https://github.com/pballhausen/moneymoney-splitwise.

## Offene Punkte
1. (erledigt 18.11.2026) Umsatzkonto in MoneyMoney vom Nutzer geprüft: Saldo, Startsaldo und
   Aufteilung Anteil/Zahlung passen. Hinweis: Änderungen am Umsatzmodell erfordern, das Konto
   in MoneyMoney zu löschen und neu anzulegen (gebuchte Umsätze bleiben sonst stehen).
2. Fremdwährungsausgaben live prüfen, sobald es welche mit Beteiligung des Nutzers gibt.
3. Neues Modell (alles gebucht + Korrekturen) in MoneyMoney prüfen: Konto löschen und neu
   anlegen (Typ wieder Sonstiges), Seitenleiste = Splitwise-Saldo, Startsaldo 0; nach einer
   Änderung in Splitwise erscheint genau eine Korrekturbuchung.
4. (erledigt 23.11.2026) Neue Darstellung (Name = Beschreibung) vom Nutzer in MoneyMoney
   geprüft und für gut befunden; Tagessalden −337,06 / −360,86 EUR wie erwartet.

## Regeln
- Den API-Key nie committen (`.env` ist ignoriert).
- MoneyMoney-API-Doku: https://moneymoney.app/api/webbanking/
- Splitwise-API: https://dev.splitwise.com/ (Basis https://secure.splitwise.com/api/v3.0/, Bearer-Key)
