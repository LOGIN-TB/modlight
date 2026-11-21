# Claude Code und Codex

Claude Code von Anthropic und Codex von OpenAI laufen im Terminal. Beide lassen sich mit einem Modell in Podlight verwenden. Podlight reicht dafür die Schnittstellen durch, die sie brauchen: die Anthropic-Messages-API für Claude Code und die Responses-API für Codex. vLLM und llama.cpp beherrschen beide.

## Vorher

- Das Modell braucht Werkzeugaufrufe, sonst kann der Agent keine Dateien bearbeiten und keine Befehle ausführen. Podlight zeigt das bei der Prüfung.
- Beide Agenten schicken lange Anweisungen mit. Stell mindestens 128.000 Token Kontext ein, besser 200.000. Ist es weniger, warnt Podlight bei den Konfigurationen.
- Starte das Modell vorher in Podlight. Ein neuer Pod braucht länger, als die Agenten warten.

## Claude Code

Installieren im Terminal:

```
curl -fsSL https://claude.ai/install.sh | bash
```

Unter „Verbindung“ → „Konfigurationsdateien für Fortgeschrittene“ → „Claude Code“ steht ein fertiger Befehl mit deiner Adresse, deinem Schlüssel und dem Modellnamen. Er startet Claude Code einmalig mit Podlight. Darunter steht dieselbe Einstellung als Funktion `claude-podlight` für die Datei `~/.zshrc`. Danach öffnest du ein neues Terminal und startest mit `claude-podlight`. Der normale Befehl `claude` behält deine übliche Anmeldung.

Gut zu wissen: Anthropic unterstützt andere Modelle in Claude Code nicht offiziell. Es funktioniert über die Anthropic-kompatible Schnittstelle, die Websuche und einige neuere Funktionen gehen aber nicht.

## Codex

Installieren im Terminal (braucht Node.js):

```
npm install -g @openai/codex
```

Unter „Codex“ stehen zwei Teile: ein Anbieter `podlight` für die Datei `~/.codex/config.toml` und eine Funktion `codex-podlight` für `~/.zshrc`. „Ordner im Finder öffnen“ zeigt den Ordner `.codex`. Danach startest du mit `codex-podlight`. Der normale Befehl `codex` bleibt, wie er war.

Die Konfigurationen enthalten deinen Podlight-Schlüssel. Leg sie in deinen Benutzerordner, nie in ein Projekt-Repository.
