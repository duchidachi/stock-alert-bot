#!/usr/bin/env bash
# Richtet den Aktien-Alarm-Bot ein bzw. ändert ihn später.
#   1) Telegram-Bot verbinden (Token aus Zwischenablage, Chat-ID automatisch)
#   2) Watchlist + optionale Einstiegskurse
#   3) Schwellen
#   4) optional Finnhub-Key (englische US-News)
# Alles landet NUR als verschlüsseltes GitHub-Secret. Nichts wird lokal gespeichert,
# nichts landet im Repo. Jeder Schritt lässt sich überspringen (Enter).
set -euo pipefail
cd "$(dirname "$0")"

have_secret() { gh secret list --json name -q '.[].name' 2>/dev/null | grep -qx "$1"; }
ask() { local a; read -r -p "$1" a </dev/tty; printf '%s' "$a"; }
LS="https://www.ls-tc.de/_rpc/json/.lstc/instrument/search/main?localeId=2&q="

# ------------------------------------------------------------------ 1 Telegram
echo "== 1/4 Telegram-Bot =="
DO_TG="j"
if have_secret TELEGRAM_BOT_TOKEN && have_secret TELEGRAM_CHAT_ID; then
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
  api() { curl -fsS "https://api.telegram.org/bot${TOKEN}/$1" "${@:2}"; }
  USERNAME="$( (api getMe || true) | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["username"])' 2>/dev/null || true)"
  [[ -z "$USERNAME" ]] && { echo "✗ Token ungültig. Nochmal komplett aus dem BotFather-Chat kopieren."; exit 1; }
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
  [[ -z "$CHAT" ]] && { echo "✗ Keine Nachricht angekommen. Beim richtigen Bot auf START getippt? Skript nochmal starten."; exit 1; }
  printf '%s' "$TOKEN" | gh secret set TELEGRAM_BOT_TOKEN
  printf '%s' "$CHAT"  | gh secret set TELEGRAM_CHAT_ID
  unset TOKEN CHAT
  echo "✓ Telegram in GitHub gespeichert"
else
  echo "→ übersprungen"
fi

# ------------------------------------------------------------------ 2 Watchlist
echo
echo "== 2/4 Watchlist =="
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
      DROP="$(ask "Alarm bei wie viel % unter Einstieg? [10]: ")"; DROP="${DROP:-10}"
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

# ------------------------------------------------------------------ 3 Schwellen
echo
echo "== 3/4 Schwellen =="
echo "Standard: ±4 % zum Vortag, ±2 % in 60 min, Übersicht morgens (8:15) + abends (22:15), max. 3 News/Tag/Firma."
echo "Eigene Werte z. B.:  tag=5 schnell=3 fenster=60 uebersicht=abend news_max=2   (uebersicht=aus = keine)"
SET="$(ask "Enter = Standard behalten, sonst eigene Zeile: ")"
if [[ -n "$SET" ]]; then printf '%s' "$SET" | gh secret set SETTINGS; echo "✓ Schwellen gespeichert"
elif ! have_secret SETTINGS; then printf '%s' "tag=4 schnell=2 fenster=60 uebersicht=morgen,abend" | gh secret set SETTINGS; echo "✓ Standard gespeichert"
else echo "→ unverändert"; fi

# ------------------------------------------------------------------ 4 Finnhub
echo
echo "== 4/4 Finnhub (optional, englische US-News) =="
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
gh workflow run stock-bot.yml -f mode=test && echo "✓ Fertig. In 1–2 Minuten sollten Testnachricht und Probe-Alarm auf dem Handy sein."
