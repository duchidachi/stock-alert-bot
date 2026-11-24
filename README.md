# Aktien-Alarm-Bot

Ein kleiner Telegram-Bot, der eine private Watchlist überwacht und Bescheid gibt bei:

1. **Kursalarm**: Bewegung zum Vortagesschluss (Standard ±4 %, danach erneut bei ±8 %, …)
   und schnelle Bewegung (Standard ±2 % innerhalb von 60 min). Jede Meldung bringt Kurs,
   %-Änderung und die 3 neuesten Schlagzeilen mit.
2. **Einstiegs-Alarm** (optional): Kurs fällt X % unter deinen Kaufkurs oder unter einen festen Alarmkurs.
   **Zielkurs-Alarm** (optional): Kurs erreicht deinen Wunschkurs, z. B. zum Nachkaufen (fallend)
   oder zum Gewinnmitnehmen (steigend). Meldet einmal, scharf wieder nach 3 % Abstand.
3. **Schlagzeilen-Wächter**: wichtige News auch ohne Kurssprung (CEO, Rücktritt/Rückkehr,
   Quartalszahlen, Prognose, Übernahme, Klage, Dividende, Rückkauf, Ad-hoc …),
   dedupliziert, höchstens 3 pro Firma und Tag.
4. **Übersicht** werktags um 8:15 und 22:15 (abschaltbar).

> Der Bot liefert nur Informationen. Er gibt keine Anlageberatung und keine Kauf- oder
> Verkaufsempfehlungen. Entscheidungen triffst du selbst.

## Datenschutz (öffentliches Repo)

Das Repo ist öffentlich, damit GitHub Actions unbegrenzt kostenlos laufen. Damit trotzdem
nichts Privates sichtbar wird:

- Watchlist, Einstiegskurse, Schwellen, Telegram-Token und Chat-ID stehen **nur in
  verschlüsselten GitHub-Secrets**, nicht im Code und nicht in Commits.
- Der Zustand (welche Meldungen schon raus sind) wird **nicht committet**. Er liegt
  AES-256-verschlüsselt im Actions-Cache (Schlüssel = Secret `STATE_KEY`, nie sichtbar).
- Die Actions-Logs sind öffentlich. Deshalb gibt das Skript dort nur Zählwerte aus
  (z. B. `geprüft: 3 Werte, 3 Kurse, 0 Alarme`), nie Namen, ISINs, Kurse oder Schlagzeilen.

## Datenquellen

| Was | Quelle | Hinweis |
|---|---|---|
| Kurse (EUR, ~7:30 bis 23:00) | Lang & Schwarz Tradecenter (ls-tc.de) | gleiche Handelsplatz-Kurse wie bei Trade Republic; robots.txt erlaubt Abruf, private Nutzung |
| News (deutsch + englisch) | finanznachrichten.de, offizieller RSS-Feed pro ISIN | |
| News (englisch, US-Werte) | Finnhub `company-news` | optional, braucht kostenlosen API-Key |

Nicht genutzt: Yahoo, Stooq und Google-News-RSS, weil deren robots.txt automatische
Abrufe verbietet. Finnhub free liefert keine Xetra-Kurse, deshalb kommen die Kurse von L&S.

## Einrichtung

Voraussetzung: `gh` ist eingeloggt (mit `workflow`-Scope).

1. **Telegram-Bot anlegen**: In Telegram `@BotFather` öffnen, `/newbot`, Namen und einen
   neutralen Benutzernamen vergeben (der muss auf `bot` enden). Das Token **nicht** in einen Chat kopieren.
2. **Optional Finnhub**: auf finnhub.io kostenlos registrieren und den API-Key kopieren.
3. **Setup-Skript** im Terminal starten:
   ```bash
   ./setup.sh
   ```
   Das Skript
   - liest das Bot-Token aus der Zwischenablage, du tippst im Bot auf START, die Chat-ID kommt automatisch
     (bremst Telegram gerade, verbindet sich der Bot auf GitHub später selbst: die erste
     private Nachricht an den Bot legt den Chat fest, gespeichert im verschlüsselten Zustand);
   - fragt die Watchlist ab: Firmenname oder ISIN eingeben, Treffer auswählen, optional
     Einstiegskurs und „Alarm bei X % unter Einstieg“;
   - fragt Schwellen und Finnhub-Key (beides optional);
   - speichert alles als Secret, startet den Bot neu und schickt **Testnachricht + Probe-Alarm**.

Später ändern (Watchlist, Schwellen …): einfach `./setup.sh` nochmal starten, nicht
benötigte Schritte mit Enter überspringen. Die Watchlist wird dabei immer komplett neu eingegeben.

### Schwellen (Secret `SETTINGS`)

```
tag=4 schnell=2 fenster=60 uebersicht=morgen,abend news_max=3
```

`uebersicht=abend` = nur abends, `uebersicht=aus` = keine Übersicht.

### Zielkurse (Secret `ZIELE`)

Eine Zeile pro Ziel: `Name; ISIN; Kurs`. `60` = Richtung automatisch (liegt der Kurs drüber,
wartet der Bot aufs Fallen), `<60` = fällt auf/unter 60 €, `>120` = steigt auf/über 120 €.
Mehrere Ziele pro Wert gehen, auch für Werte außerhalb der Watchlist. Am einfachsten über
`./setup.sh`, Schritt 3.

### Watchlist-Format (Secret `WATCHLIST`)

Eine Zeile pro Wert: `Name; ISIN; Einstiegskurs; Alarm; US-Ticker`. Alarm = `10` (10 % unter Einstieg) oder `20 €` (fester Kurs). Nur Name und
ISIN sind Pflicht. Normalerweise erzeugt `setup.sh` das für dich.

## Betrieb

- Workflow `.github/workflows/stock-bot.yml`: läuft je ~5,5 h und prüft alle 5 min.
  Am Ende startet er sich selbst neu. Der Stunden-Cron ist nur Reserve, weil GitHub-Cron
  allein oft stundenlang aussetzt.
- Manuell testen: Actions → *Aktien-Alarm-Bot* → *Run workflow* → `mode = test`
  (Testnachricht + Probe-Alarm) oder `probe`. Ein laufender Durchgang muss dafür vorher
  abgebrochen werden, sonst wartet der neue in der Schlange.
- Stoppen: laufenden Run abbrechen (dann startet keine neue Runde) und den Workflow unter
  Actions → *Disable workflow* deaktivieren.
- Lokal ausprobieren (zeigt alles in der Konsole, sendet nichts):
  ```bash
  WATCHLIST='SAP; DE0007164600' python3 stock_bot.py --dry-run
  ```
