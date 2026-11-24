#!/usr/bin/env bash
# Richtet den Aktien-Alarm-Bot ein bzw. ändert ihn später.
#   1) Telegram-Bot verbinden (Token aus Zwischenablage, Chat-ID automatisch)
#   2) Watchlist + optionale Einstiegskurse
#   3) Zielkurse (z. B. Wunsch-Einstieg)
#   4) Schwellen
#   5) optional Finnhub-Key (englische US-News)
# Alles landet NUR als verschlüsseltes GitHub-Secret. Nichts wird lokal gespeichert,
# nichts landet im Repo. Jeder Schritt lässt sich überspringen (Enter).
set -euo pipefail
cd "$(dirname "$0")"

have_secret() { gh secret list --json name -q '.[].name' 2>/dev/null | grep -qx "$1"; }
ask() { local a; read -r -p "$1" a </dev/tty; printf '%s' "$a"; }
LS="https://www.ls-tc.de/_rpc/json/.lstc/instrument/search/main?localeId=2&q="

# ------------------------------------------------------------------ 1 Telegram
echo "== 1/5 Telegram-Bot =="
DO_TG="j"
if have_secret TELEGRAM_BOT_TOKEN; then
  DO_TG="$(ask "Telegram ist schon eingerichtet. Neu verbinden? [j/N] ")"
fi
if [[ "$DO_TG" =~ ^[jJyY] ]]; then
  echo "Kopiere das Token (oder die ganze BotFather-Nachricht) und drück dann Enter."
  echo "(Du kannst es auch hier einfügen, die Eingabe ist unsichtbar.)"
  read -r -s RAW </dev/tty || true; echo
  [[ -z "$RAW" ]] && RAW="$(pbpaste 2>/dev/null || true)" && echo "→ nehme Token aus der Zwischenablage"
  TOKEN="$(printf '%s' "$RAW" | grep -oE '[0-9]{8,12}:[A-Za-z0-9_-]{30,}' | head -1 || true)"
  unset RAW
  [[ -z "$TOKEN" ]] && { echo "✗ Kein Token gefunden (sieht aus wie 1234567890:AAH…). Skript neu starten."; exit 1; }
  api() { curl -sS "https://api.telegram.org/bot${TOKEN}/$1" "${@:2}"; }
  USERNAME=""
  for try in 1 2; do
    RES="$(api getMe 2>/dev/null || true)"
    IFS="|" read -r USERNAME WAIT ERR < <(printf '%s' "$RES" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
if d.get("ok"): print(d["result"]["username"]+"|0|-")
else: print("|%s|%s" % ((d.get("parameters") or {}).get("retry_after", 0), d.get("error_code", "netz")))' 2>/dev/null || echo "|0|netz")
    [[ -n "$USERNAME" ]] && break
    if [[ "$ERR" == "401" || "$ERR" == "404" ]]; then
      echo "✗ Telegram sagt: Token ungültig. Nochmal komplett aus dem BotFather-Chat kopieren."; exit 1
    fi
    [[ $try -lt 2 ]] && { echo "… Telegram antwortet von hier nicht (Fehler $ERR), nochmal in 10s"; sleep 10; }
  done
  unset RES
  printf '%s' "$TOKEN" | gh secret set TELEGRAM_BOT_TOKEN
  if [[ -n "$USERNAME" ]]; then
    # --- direkter Weg vom Mac
    echo "✓ Bot gefunden: @$USERNAME"
    api deleteWebhook >/dev/null || true
    echo "Öffne jetzt https://t.me/$USERNAME und tippe auf START. Ich warte bis zu 3 Minuten …"
    open "https://t.me/$USERNAME" 2>/dev/null || true
    CHAT=""
    for _ in $(seq 1 36); do
      CHAT="$( (api getUpdates || true) | python3 -c '
import sys,json
try: r=json.load(sys.stdin).get("result",[])
except Exception: r=[]
ids=[u[k]["chat"]["id"] for u in r for k in ("message","my_chat_member") if k in u]
print(ids[-1] if ids else "")' )"
      [[ -n "$CHAT" ]] && break
      sleep 5
    done
  else
    # --- Telegram drosselt gerade: der Bot auf GitHub verbindet sich später selbst
    CHAT=""
    gh secret delete TELEGRAM_CHAT_ID >/dev/null 2>&1 || true
    openssl rand -base64 32 | tr -d '\n' | gh secret set STATE_KEY >/dev/null   # alten Zustand verwerfen
    echo "→ Telegram bremst gerade Bot-Anfragen (Fehler $ERR). Kein Problem:"
    echo "  Das Token ist gespeichert. Tipp in Telegram bei deinem neuen Bot auf START (falls noch nicht)."
    echo "  Der Bot auf GitHub verbindet sich automatisch, sobald Telegram wieder Anfragen durchlässt."
  fi
  if [[ -n "$CHAT" ]]; then
    printf '%s' "$CHAT"  | gh secret set TELEGRAM_CHAT_ID
    echo "✓ Chat verbunden"
  fi
  unset TOKEN CHAT
  echo "✓ Telegram in GitHub gespeichert"
else
  echo "→ übersprungen"
fi

# ------------------------------------------------------------------ 2 Watchlist
echo
echo "== 2/5 Watchlist =="
DO_WL="j"
if have_secret WATCHLIST; then
  DO_WL="$(ask "Es gibt schon eine Watchlist. Komplett neu eingeben? [j/N] ")"
fi
if [[ "$DO_WL" =~ ^[jJyY] ]]; then
  echo "Gib pro Wert einen Suchbegriff (Firmenname) oder die ISIN ein. Enter ohne Eingabe = fertig."
  WL=""
  while true; do
    echo
    Q="$(ask "Suchbegriff/ISIN: ")"
    [[ -z "$Q" ]] && break
    HITS="$(curl -fsS -A "Mozilla/5.0" "${LS}$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$Q")" \
      | python3 -c '
import sys,json
try: r=json.load(sys.stdin)
except Exception: r=[]
for d in r[:6]:
    if d.get("isin") and d.get("categorySymbol")=="STK":
        print(d["isin"]+"\t"+d["displayname"].strip())' || true)"
    if [[ -z "$HITS" ]]; then echo "✗ Nichts gefunden, anderen Begriff probieren."; continue; fi
    i=0; while IFS=$'\t' read -r isin nm; do i=$((i+1)); echo "  $i) $nm  ($isin)"; done <<< "$HITS"
    PICK="$(ask "Welche Nummer? [1] ")"; PICK="${PICK:-1}"
    LINE="$(sed -n "${PICK}p" <<< "$HITS")"
    [[ -z "$LINE" ]] && { echo "✗ Ungültige Nummer."; continue; }
    ISIN="${LINE%%$'\t'*}"; DEF="${LINE#*$'\t'}"
    NAME="$(ask "Anzeigename [$DEF]: ")"; NAME="${NAME:-$DEF}"; NAME="${NAME//;/,}"
    ENTRY="$(ask "Dein Einstiegskurs in € (Enter = keiner): ")"
    DROP=""
    if [[ -n "$ENTRY" ]]; then
      DROP="$(ask "Alarm ab: Prozent unter Einstieg (z. B. 10) ODER fester Kurs mit € (z. B. 20 €) [10]: ")"; DROP="${DROP:-10}"
    fi
    TICKER=""
    [[ "$ISIN" == US* ]] && TICKER="$(ask "US-Ticker für englische Finnhub-News (optional, z. B. aus der Kursliste): ")"
    WL+="${NAME}; ${ISIN}; ${ENTRY}; ${DROP}; ${TICKER}"$'\n'
    echo "✓ $NAME aufgenommen"
  done
  if [[ -n "$WL" ]]; then
    echo; echo "Deine Watchlist (Name; ISIN; Einstieg; Minus-%; Ticker):"; printf '%s' "$WL" | sed 's/^/  /'
    OK="$(ask "So speichern? [J/n] ")"
    if [[ ! "$OK" =~ ^[nN] ]]; then printf '%s' "$WL" | gh secret set WATCHLIST; echo "✓ Watchlist gespeichert"; fi
  else
    echo "→ keine Werte eingegeben, alte Watchlist bleibt"
  fi
  unset WL
else
  echo "→ übersprungen"
fi

# ------------------------------------------------------------------ 3 Zielkurse
echo
echo "== 3/5 Zielkurse (z. B. Wunsch-Einstieg zum Nachkaufen) =="
if have_secret ZIELE; then Q0="Es gibt schon Zielkurse. Komplett neu eingeben? [j/N] "; else Q0="Zielkurse einrichten? [j/N] "; fi
DO_Z="$(ask "$Q0")"
if [[ "$DO_Z" =~ ^[jJyY] ]]; then
  echo "Pro Ziel: Firmenname/ISIN suchen, dann Kurs in €. Enter ohne Eingabe = fertig."
  echo "Kurs einfach als Zahl (z. B. 60). Optional: <60 = Alarm wenn er auf/unter 60 € fällt, >120 = wenn er auf/über 120 € steigt."
  Z=""
  while true; do
    echo
    Q="$(ask "Suchbegriff/ISIN: ")"
    [[ -z "$Q" ]] && break
    HITS="$(curl -fsS -A "Mozilla/5.0" "${LS}$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$Q")" \
      | python3 -c '
import sys,json
try: r=json.load(sys.stdin)
except Exception: r=[]
for d in r[:6]:
    if d.get("isin") and d.get("categorySymbol")=="STK":
        print(d["isin"]+"\t"+d["displayname"].strip())' || true)"
    if [[ -z "$HITS" ]]; then echo "✗ Nichts gefunden, anderen Begriff probieren."; continue; fi
    i=0; while IFS=$'\t' read -r isin nm; do i=$((i+1)); echo "  $i) $nm  ($isin)"; done <<< "$HITS"
    PICK="$(ask "Welche Nummer? [1] ")"; PICK="${PICK:-1}"
    LINE="$(sed -n "${PICK}p" <<< "$HITS")"
    [[ -z "$LINE" ]] && { echo "✗ Ungültige Nummer."; continue; }
    ISIN="${LINE%%$'\t'*}"; DEF="${LINE#*$'\t'}"
    NAME="$(ask "Anzeigename [$DEF]: ")"; NAME="${NAME:-$DEF}"; NAME="${NAME//;/,}"
    while true; do
      K="$(ask "Zielkurs in € (z. B. 60 oder <60 oder >120): ")"
      [[ "$K" =~ ^[\<\>]?[[:space:]]*[0-9]+([.,][0-9]+)?[[:space:]]*(€|EUR|eur)?$ ]] && break
      echo "✗ Bitte nur eine Zahl, optional mit < oder > davor."
    done
    Z+="${NAME}; ${ISIN}; ${K}"$'\n'
    echo "✓ Ziel für $NAME aufgenommen"
  done
  if [[ -n "$Z" ]]; then
    echo; echo "Deine Zielkurse (Name; ISIN; Kurs):"; printf '%s' "$Z" | sed 's/^/  /'
    OK="$(ask "So speichern? [J/n] ")"
    if [[ ! "$OK" =~ ^[nN] ]]; then printf '%s' "$Z" | gh secret set ZIELE; echo "✓ Zielkurse gespeichert"; fi
  else
    DEL="$(ask "Keine Ziele eingegeben. Alle bisherigen Zielkurse löschen? [j/N] ")"
    [[ "$DEL" =~ ^[jJyY] ]] && { gh secret delete ZIELE >/dev/null 2>&1 || true; echo "✓ Zielkurse gelöscht"; }
  fi
  unset Z
else
  echo "→ übersprungen"
fi

# ------------------------------------------------------------------ 4 Schwellen
echo
echo "== 4/5 Schwellen =="
echo "Standard: ±4 % zum Vortag, ±2 % in 60 min, Übersicht morgens (8:15) + abends (22:15), max. 3 News/Tag/Firma."
echo "Eigene Werte z. B.:  tag=5 schnell=3 fenster=60 uebersicht=abend news_max=2   (uebersicht=aus = keine)"
SET="$(ask "Enter = Standard behalten, sonst eigene Zeile: ")"
if [[ -n "$SET" ]]; then printf '%s' "$SET" | gh secret set SETTINGS; echo "✓ Schwellen gespeichert"
elif ! have_secret SETTINGS; then printf '%s' "tag=4 schnell=2 fenster=60 uebersicht=morgen,abend" | gh secret set SETTINGS; echo "✓ Standard gespeichert"
else echo "→ unverändert"; fi

# ------------------------------------------------------------------ 5 Finnhub
echo
echo "== 5/5 Finnhub (optional, englische US-News) =="
FH="$(ask "Finnhub-Key einrichten? Kopier ihn zuerst, dann 'j' + Enter. [j/N] ")"
if [[ "$FH" =~ ^[jJyY] ]]; then
  KEY="$(pbpaste 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$KEY" =~ ^[A-Za-z0-9]{15,}$ ]] && curl -fsS "https://finnhub.io/api/v1/quote?symbol=AAPL&token=$KEY" >/dev/null 2>&1; then
    printf '%s' "$KEY" | gh secret set FINNHUB_API_KEY; echo "✓ Finnhub-Key geprüft und gespeichert"
  else
    echo "✗ In der Zwischenablage war kein gültiger Finnhub-Key. Später nochmal versuchen."
  fi
  unset KEY
else
  echo "→ übersprungen"
fi

# ------------------------------------------------------------------ Schlüssel + Start
if ! have_secret STATE_KEY; then
  openssl rand -base64 32 | tr -d '\n' | gh secret set STATE_KEY
  echo "✓ Schlüssel für den verschlüsselten Zustand erzeugt"
fi

echo
echo "Starte den Bot auf GitHub neu (mit Testnachricht + Probe-Alarm) …"
for id in $(gh run list --workflow stock-bot.yml --status in_progress --json databaseId -q '.[].databaseId'); do gh run cancel "$id" >/dev/null || true; done
for id in $(gh run list --workflow stock-bot.yml --status queued --json databaseId -q '.[].databaseId'); do gh run cancel "$id" >/dev/null || true; done
gh workflow enable stock-bot.yml >/dev/null 2>&1 || true
sleep 5
if [[ "$DO_TG" =~ ^[jJyY] ]]; then
  gh workflow run stock-bot.yml -f mode=test && echo "✓ Fertig. In 1–2 Minuten sollten Testnachricht und Probe-Alarm auf dem Handy sein."
else
  gh workflow run stock-bot.yml -f mode=normal && echo "✓ Fertig. Der Bot läuft mit den neuen Einstellungen."
fi
