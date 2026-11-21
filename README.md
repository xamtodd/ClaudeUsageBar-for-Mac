# ClaudeUsageBar

Menüleisten-App für macOS (13+), die live zeigt, wie viel vom **5-Stunden-Limit** und vom **Wochenlimit** deines Claude-Abos verbraucht ist – und wann es zurückgesetzt wird.

Menüleiste: `5h 42% · W 18%` – Klick öffnet Details mit Balken, Countdown und Reset-Zeitpunkt.

## Installieren

```bash
./build.sh
```

Baut die App, legt sie nach `~/Applications` und startet sie. Autostart: im Panel unter *Einstellungen → Bei Anmeldung starten*.

## Datenquelle

1. **Claude Code (empfohlen):** Liest den OAuth-Token, den Claude Code in der Keychain (`Claude Code-credentials`) bzw. in `~/.claude/.credentials.json` ablegt, und fragt `api.anthropic.com/api/oauth/usage` ab. Einfach einmal `claude` → `/login` gemacht haben.
2. **Fallback claude.ai:** In den Einstellungen den `sessionKey`-Cookie von claude.ai eintragen (Browser → DevTools → Application → Cookies → `sessionKey`).

Beim ersten Keychain-Zugriff fragt macOS evtl. nach Erlaubnis → *Immer erlauben*.

Hinweis: Beides sind inoffizielle Endpunkte, die sich ändern können. Die App refresht den Token **nicht** selbst (würde Claude Code ausloggen) – ist er abgelaufen, einmal `claude` starten.
