#!/usr/bin/env python3
"""Aktien-Alarm-Bot: Kursalarme + Schlagzeilen per Telegram.

Nur Python-Standardbibliothek. Alle persönlichen Angaben (Watchlist, Einstiegskurse,
Schwellen) kommen aus Umgebungsvariablen (GitHub-Secrets) – nie aus dem Code.

WICHTIG fürs öffentliche Repo: Dieses Skript schreibt NIE Namen, ISINs, Kurse oder
Schlagzeilen in die Konsole (die Actions-Logs sind öffentlich). Ausnahme: --dry-run,
das nur lokal auf deinem Mac gedacht ist.

Datenquellen:
  - Kurse: Lang & Schwarz Tradecenter (ls-tc.de), dieselben Kurse wie bei Trade Republic,
    in Euro. robots.txt erlaubt Abrufe, Nutzung privat/nicht-kommerziell.
  - News: offizielle RSS-Feeds von finanznachrichten.de (pro ISIN).
  - Optional: Finnhub company-news (englisch, US-Werte), wenn FINNHUB_API_KEY gesetzt ist.

Aufruf:
  python3 stock_bot.py            normaler Durchlauf (alle 5 min vom Workflow)
  python3 stock_bot.py --test     Telegram-Testnachricht
  python3 stock_bot.py --probe    Probe-Kursalarm (mit echten Daten, als TEST markiert)
  python3 stock_bot.py --dry-run  nur lokal: zeigt alles in der Konsole, sendet nichts
"""
from __future__ import annotations

import datetime as dt
import hashlib
import html
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Europe/Berlin")
UA = "Mozilla/5.0 (private stock-alert-bot; low-frequency personal use)"
STATE_FILE = os.environ.get("STATE_FILE", "state.json")
DISCLAIMER = "<i>Nur Info, keine Anlageberatung.</i>"

NEWS_KEYWORDS = [
    # Personal / Führung
    r"\bceo\b", r"vorstandschef", r"vorstandsvorsitz", r"chief executive", r"rücktritt",
    r"tritt zurück", r"resign", r"steps down", r"rückkehr", r"kehrt zurück", r"returns? as", r"comeback",
    r"\bcfo\b", r"aufsichtsrat",
    # Zahlen / Ausblick
    r"quartal", r"\bq[1-4]\b", r"earnings", r"results", r"jahreszahlen", r"geschäftszahlen",
    r"prognose", r"guidance", r"ausblick", r"outlook", r"gewinnwarnung", r"profit warning",
    r"umsatz", r"revenue",
    # Deals / Recht / Kapital
    r"übernahme", r"übernimmt", r"acquisition", r"acquire", r"merger", r"fusion",
    r"klage", r"lawsuit", r"\bsues?\b", r"kartell", r"antitrust", r"ermittlung", r"investigation",
    r"dividende", r"dividend", r"aktienrückkauf", r"buyback", r"kapitalerhöhung",
    r"ad-hoc", r"insolvenz", r"lock-up", r"lockup",
]
NEWS_RE = re.compile("|".join(NEWS_KEYWORDS), re.I)


# ---------------------------------------------------------------- Konfiguration
def parse_num(s: str) -> float | None:
    s = (s or "").strip().replace("€", "").replace("%", "").replace(" ", "")
    if not s:
        return None
    if "," in s and "." in s:
        s = s.replace(".", "")
    s = s.replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return None


def load_watchlist() -> list[dict]:
    """WATCHLIST: eine Zeile pro Wert:  Name; ISIN; Einstiegskurs; Minus-%; Ticker
    Nur Name und ISIN sind Pflicht. Beispiel (erfunden):  Beispiel AG; DE0001234567; 20,50; 10; """
    items = []
    for line in os.environ.get("WATCHLIST", "").replace("\\n", "\n").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split(";")] + [""] * 5
        name, isin = parts[0], parts[1].upper()
        if not re.fullmatch(r"[A-Z]{2}[A-Z0-9]{9}[0-9]", isin):
            continue
        items.append({
            "name": name or isin,
            "isin": isin,
            "entry": parse_num(parts[2]),
            "drop": parse_num(parts[3]) or 10.0,
            "ticker": parts[4].upper(),
        })
    return items


def load_settings() -> dict:
    """SETTINGS (optional): z. B.  tag=4 schnell=2 fenster=60 uebersicht=morgen,abend"""
    s = {"tag": 4.0, "schnell": 2.0, "fenster": 60.0, "uebersicht": "morgen,abend",
         "news_max": 3.0}
    for tok in os.environ.get("SETTINGS", "").replace(";", " ").split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            k = k.strip().lower()
            if k == "uebersicht":
                s[k] = v.strip().lower()
            elif k in s and parse_num(v) is not None:
                s[k] = parse_num(v)
    return s


# ---------------------------------------------------------------- HTTP
def get(url: str, timeout: int = 20) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def get_json(url: str):
    return json.loads(get(url).decode("utf-8"))


# ---------------------------------------------------------------- Kurse (L&S)
LS = "https://www.ls-tc.de/_rpc/json"


def ls_instrument(isin: str, state: dict) -> int | None:
    cache = state.setdefault("ls_ids", {})
    if isin in cache:
        return cache[isin]
    res = get_json(f"{LS}/.lstc/instrument/search/main?q={urllib.parse.quote(isin)}&localeId=2")
    for r in res:
        if str(r.get("isin", "")).upper() == isin:
            cache[isin] = int(r["instrumentId"])
            return cache[isin]
    return None


def ls_quote(instrument_id: int) -> dict | None:
    d = get_json(f"{LS}/instrument/chart/dataForInstrument?instrumentId={instrument_id}"
                 f"&marketId=1&quotetype=mid&series=intraday&localeId=2")
    prev = None
    for pl in (d.get("info") or {}).get("plotlines") or []:
        if pl.get("id") == "previousDay":
            prev = float(pl["value"])
    series = ((d.get("series") or {}).get("intraday") or {}).get("data") or []
    # L&S kodiert Berliner Ortszeit als wäre sie UTC -> in echte Zeitstempel umrechnen
    utc = dt.timezone.utc
    series = [(dt.datetime.fromtimestamp(int(t) / 1000, utc).replace(tzinfo=TZ).timestamp(), float(p))
              for t, p in series if p is not None]
    if not series or not prev:
        return None
    return {"prev": prev, "series": series, "price": series[-1][1], "ts": series[-1][0]}


def price_minutes_ago(series, minutes: float):
    target = series[-1][0] - minutes * 60
    older = [(t, p) for t, p in series if t <= target]
    if not older:
        return None
    t, p = older[-1]
    if target - t > 15 * 60:  # Lücke (z. B. Handelspause) -> nicht vergleichen
        return None
    return p


# ---------------------------------------------------------------- News
def fn_news(isin: str) -> list[dict]:
    raw = get(f"https://www.finanznachrichten.de/rss-x-aktien-{isin.lower()}")
    root = ET.fromstring(raw)
    out = []
    for it in root.iter("item"):
        title = html.unescape((it.findtext("title") or "").strip())
        pub = it.findtext("pubDate") or ""
        try:
            ts = dt.datetime.fromisoformat(pub.replace("Z", "+00:00")).timestamp()
        except ValueError:
            ts = time.time()
        if title:
            out.append({"title": title, "ts": ts, "link": (it.findtext("link") or "").strip(),
                        "src": "finanznachrichten.de"})
    return out


def finnhub_news(ticker: str) -> list[dict]:
    key = os.environ.get("FINNHUB_API_KEY", "").strip()
    if not key or not ticker:
        return []
    today = dt.date.today()
    url = ("https://finnhub.io/api/v1/company-news?" + urllib.parse.urlencode({
        "symbol": ticker, "from": (today - dt.timedelta(days=3)).isoformat(),
        "to": today.isoformat(), "token": key}))
    out = []
    for n in get_json(url)[:30]:
        if n.get("headline"):
            out.append({"title": n["headline"].strip(), "ts": float(n.get("datetime") or 0),
                        "link": n.get("url", ""), "src": n.get("source") or "Finnhub"})
    return out


def all_news(item: dict) -> list[dict]:
    news = []
    for fn in (lambda: fn_news(item["isin"]), lambda: finnhub_news(item["ticker"])):
        try:
            news += fn()
        except Exception:
            pass
    news.sort(key=lambda n: n["ts"], reverse=True)
    return news


def news_id(title: str) -> str:
    norm = re.sub(r"[^a-z0-9äöüß]+", " ", title.lower()).strip()
    return hashlib.sha1(norm.encode()).hexdigest()[:12]


# ---------------------------------------------------------------- Telegram
def esc(s: str) -> str:
    return html.escape(s, quote=False)


def send(text: str, dry: bool) -> None:
    if dry:
        print("-" * 60 + "\n" + re.sub(r"<[^>]+>", "", text))
        return
    token = os.environ["TELEGRAM_BOT_TOKEN"]
    chat = os.environ["TELEGRAM_CHAT_ID"]
    data = urllib.parse.urlencode({"chat_id": chat, "text": text, "parse_mode": "HTML",
                                   "disable_web_page_preview": "true"}).encode()
    req = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage", data=data)
    with urllib.request.urlopen(req, timeout=20) as r:
        r.read()
    time.sleep(1)


def fmt_eur(x: float) -> str:
    return f"{x:,.2f} €".replace(",", "X").replace(".", ",").replace("X", ".")


def fmt_pct(x: float) -> str:
    return f"{x:+.1f} %".replace(".", ",")


def headlines_block(news: list[dict], n: int = 3) -> str:
    if not news:
        return "<i>Keine aktuellen Schlagzeilen gefunden.</i>"
    lines = []
    for item in news[:n]:
        when = dt.datetime.fromtimestamp(item["ts"], TZ).strftime("%d.%m. %H:%M")
        title = esc(item["title"])
        if item.get("link"):
            title = f'<a href="{esc(item["link"])}">{title}</a>'
        lines.append(f"• {title} <i>({when}, {esc(item['src'])})</i>")
    return "\n".join(lines)


def price_alert(item, q, kind: str, detail: str, news, test=False, arrow="") -> str:
    day = (q["price"] / q["prev"] - 1) * 100
    arrow = arrow or ("🟢📈" if day >= 0 else "🔴📉")
    head = "🧪 TEST – " if test else ""
    when = dt.datetime.fromtimestamp(q["ts"], TZ).strftime("%H:%M")
    return (f"{head}{arrow} <b>{esc(item['name'])}</b>: {kind}\n"
            f"Kurs {fmt_eur(q['price'])} ({when}, L&amp;S) · heute {fmt_pct(day)}\n"
            f"{detail}\n\n<b>Schlagzeilen:</b>\n{headlines_block(news)}\n\n{DISCLAIMER}")


# ---------------------------------------------------------------- Logik
def load_state() -> dict:
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state: dict) -> None:
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False)


def check_prices(item, q, st, settings, now, dry) -> int:
    """st = Zustand dieses Werts. Gibt Anzahl gesendeter Alarme zurück."""
    sent = 0
    today = now.strftime("%Y-%m-%d")
    day = (q["price"] / q["prev"] - 1) * 100
    news = None

    def nws():
        nonlocal news
        if news is None:
            news = all_news(item)
        return news

    # 1) Tagesbewegung: Alarm bei ±tag, dann erneut bei jeder weiteren Stufe (±2×tag …)
    step = settings["tag"]
    level = int(abs(day) // step) * (1 if day >= 0 else -1)
    if st.get("day_date") != today:
        st["day_date"], st["day_level"] = today, 0
    if level != 0 and (abs(level) > abs(st["day_level"]) or level * st["day_level"] < 0):
        send(price_alert(item, q, f"{fmt_pct(day)} zum Vortag",
                         f"Vortagesschluss {fmt_eur(q['prev'])} (Schwelle ±{step:g} %)", nws()), dry)
        st["day_level"] = level
        sent += 1

    # 2) Schnelle Bewegung im Fenster (Standard 60 min), max. 1× pro Fenster
    win = settings["fenster"]
    old = price_minutes_ago(q["series"], win)
    if old:
        fast = (q["price"] / old - 1) * 100
        if abs(fast) >= settings["schnell"] and now.timestamp() - st.get("fast_ts", 0) > win * 60:
            send(price_alert(item, q, f"{fmt_pct(fast)} in {win:g} min",
                             f"vor {win:g} min: {fmt_eur(old)} (Schwelle ±{settings['schnell']:g} %)",
                             nws()), dry)
            st["fast_ts"] = now.timestamp()
            sent += 1

    # 3) X % unter Einstieg (einmal, bis der Kurs wieder drüber ist)
    if item["entry"]:
        limit = item["entry"] * (1 - item["drop"] / 100)
        vs = (q["price"] / item["entry"] - 1) * 100
        if q["price"] <= limit and not st.get("below_entry"):
            send(price_alert(item, q, f"{item['drop']:g} %-Marke unter Einstieg erreicht",
                             f"Einstieg {fmt_eur(item['entry'])} · jetzt {fmt_pct(vs)}", nws(), arrow="🔻"), dry)
            st["below_entry"] = True
            sent += 1
        elif q["price"] > limit * 1.01:
            st["below_entry"] = False
    return sent


def check_news(item, st, settings, now, dry, first_run: bool) -> int:
    seen = st.setdefault("seen_news", {})
    today = now.strftime("%Y-%m-%d")
    if st.get("news_date") != today:
        st["news_date"], st["news_count"] = today, 0
    sent = 0
    for n in all_news(item):
        nid = news_id(n["title"])
        if nid in seen:
            continue
        seen[nid] = int(n["ts"])
        if first_run or now.timestamp() - n["ts"] > 12 * 3600:
            continue  # Altbestand nicht nachträglich melden
        if not NEWS_RE.search(n["title"]):
            continue
        if st["news_count"] >= settings["news_max"]:
            continue
        send(f"📰 <b>{esc(item['name'])}</b>\n{headlines_block([n], 1)}\n\n{DISCLAIMER}", dry)
        st["news_count"] += 1
        sent += 1
    # Speicher begrenzen: nur Meldungen der letzten 5 Tage merken
    cutoff = now.timestamp() - 5 * 86400
    st["seen_news"] = {k: v for k, v in seen.items() if v > cutoff}
    return sent


def overview(items, quotes, title: str) -> str:
    lines = [f"🗒 <b>{title}</b>"]
    for it in items:
        q = quotes.get(it["isin"])
        if not q:
            lines.append(f"• {esc(it['name'])}: kein Kurs")
            continue
        day = (q["price"] / q["prev"] - 1) * 100
        extra = ""
        if it["entry"]:
            extra = f" · seit Einstieg {fmt_pct((q['price'] / it['entry'] - 1) * 100)}"
        lines.append(f"• <b>{esc(it['name'])}</b> {fmt_eur(q['price'])} ({fmt_pct(day)}){extra}")
    return "\n".join(lines) + f"\n\n{DISCLAIMER}"


def maybe_overview(items, quotes, state, settings, now, dry) -> int:
    if now.weekday() >= 5:
        return 0
    wanted = settings["uebersicht"]
    slots = {"morgen": (8, 15, "Guten Morgen – Stand vor Xetra-Start"),
             "abend": (22, 15, "Feierabend-Übersicht")}
    sent = 0
    for key, (h, m, title) in slots.items():
        if key not in wanted:
            continue
        due = now.replace(hour=h, minute=m, second=0, microsecond=0)
        if due <= now < due + dt.timedelta(minutes=45) and state.get(f"ov_{key}") != now.strftime("%Y-%m-%d"):
            send(overview(items, quotes, title), dry)
            state[f"ov_{key}"] = now.strftime("%Y-%m-%d")
            sent += 1
    return sent


def run(dry: bool, probe: bool) -> None:
    items = load_watchlist()
    settings = load_settings()
    if not items:
        print("Watchlist leer oder ungültig (Secret WATCHLIST prüfen).")
        return
    state = load_state()
    first_run = not state.get("initialized")
    per = state.setdefault("items", {})
    now = dt.datetime.now(TZ)
    quotes, alerts, news_sent, errors = {}, 0, 0, 0

    for idx, item in enumerate(items, 1):
        st = per.setdefault(hashlib.sha1(item["isin"].encode()).hexdigest()[:10], {})
        try:
            iid = ls_instrument(item["isin"], state)
            q = ls_quote(iid) if iid else None
            if q and now.timestamp() - q["ts"] < 20 * 60:   # nur frische Kurse (Handelszeit)
                quotes[item["isin"]] = q
                if probe and idx == 1:
                    day = (q["price"] / q["prev"] - 1) * 100
                    send(price_alert(item, q, f"Probe-Alarm ({fmt_pct(day)} zum Vortag)",
                                     "So sieht ein echter Kursalarm aus. Schwellen: "
                                     f"±{settings['tag']:g} % Tag, ±{settings['schnell']:g} % in "
                                     f"{settings['fenster']:g} min.", all_news(item), test=True), dry)
                elif not first_run:
                    alerts += check_prices(item, q, st, settings, now, dry)
            elif q:
                quotes[item["isin"]] = q   # für Übersicht trotzdem letzten Kurs nutzen
                if probe and idx == 1:
                    send(price_alert(item, q, "Probe-Alarm (Markt gerade zu, letzter Kurs)",
                                     "So sieht ein echter Kursalarm aus.", all_news(item), test=True), dry)
            elif probe and idx == 1:
                send("🧪 TEST – Probe-Alarm: für den ersten Wert kam gerade kein Kurs.", dry)
        except Exception as e:  # keine Details ins öffentliche Log
            errors += 1
            print(f"Kurs-Fehler bei Wert {idx}: {type(e).__name__}")
        try:
            news_sent += check_news(item, st, settings, now, dry, first_run)
        except Exception as e:
            errors += 1
            print(f"News-Fehler bei Wert {idx}: {type(e).__name__}")

    if not probe:
        alerts += maybe_overview(items, quotes, state, settings, now, dry)
    state["initialized"] = True
    save_state(state)
    print(f"{now:%H:%M} geprüft: {len(items)} Werte, {len(quotes)} Kurse, "
          f"{alerts} Alarme, {news_sent} News, {errors} Fehler")


def main() -> None:
    args = set(sys.argv[1:])
    dry = "--dry-run" in args
    if "--test" in args:
        n = len(load_watchlist())
        send(f"✅ Aktien-Alarm-Bot ist verbunden (läuft auf GitHub). Beobachte {n} Werte.\n"
             f"Kursalarme, wichtige Schlagzeilen und Übersichten kommen hier rein.\n\n{DISCLAIMER}", dry)
        print("Testnachricht gesendet.")
        return
    run(dry, "--probe" in args)


if __name__ == "__main__":
    main()
