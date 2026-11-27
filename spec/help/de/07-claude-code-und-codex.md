# Claude Code und Codex

Claude Code von Anthropic und Codex von OpenAI laufen im Terminal. Beide lassen sich mit einem Modell in Modlight verwenden. Modlight reicht dafür die Schnittstellen durch, die sie brauchen: die Anthropic-Messages-API für Claude Code und die Responses-API für Codex. vLLM und llama.cpp beherrschen beide.

## Vorher

- Das Modell braucht Werkzeugaufrufe, sonst kann der Agent keine Dateien bearbeiten und keine Befehle ausführen. Modlight zeigt das bei der Prüfung.
- Beide Agenten schicken lange Anweisungen mit. Stell mindestens 128.000 Token Kontext ein, besser 200.000. Ist es weniger, warnt Modlight bei den Konfigurationen.
- Starte das Modell vorher in Modlight. Ein neuer Pod braucht länger, als die Agenten warten.

## Modelle von Venice

Auch ein Venice-Modell funktioniert mit beiden Agenten, ohne Pod und ohne Wartezeit. Für Claude Code übersetzt Modlight zwischen der Anthropic-Schnittstelle und der von Venice. Wähle beim Hinzufügen ein Modell mit Werkzeugaufrufen und genug Kontext. Mehr dazu unter „Venice“.

## Claude Code

Installieren im Terminal:

```
curl -fsSL https://claude.ai/install.sh | bash
```

Unter „Verbindung“ → „Konfigurationsdateien für Fortgeschrittene“ → „Claude Code“ steht ein fertiger Befehl mit deiner Adresse, deinem Schlüssel und dem Modellnamen. Er startet Claude Code einmalig mit Modlight. In einem eigenen Kasten darunter steht dieselbe Einstellung als Funktion `claude-modlight` für die Datei `~/.zshrc`. Danach öffnest du ein neues Terminal und startest mit `claude-modlight`. Der normale Befehl `claude` behält deine übliche Anmeldung. Jeder Kasten hat einen eigenen Knopf „Kopieren“, der genau diesen Teil kopiert.

Gut zu wissen: Anthropic unterstützt andere Modelle in Claude Code nicht offiziell. Es funktioniert über die Anthropic-kompatible Schnittstelle, die Websuche und einige neuere Funktionen gehen aber nicht.

## Codex

Installieren im Terminal (braucht Node.js):

```
npm install -g @openai/codex
```

Unter „Codex“ stehen zwei Teile, jeder in einem eigenen Kasten zum Kopieren: ein Anbieter `modlight` für die Datei `~/.codex/config.toml` und eine Funktion `codex-modlight` für `~/.zshrc`. „Ordner im Finder öffnen“ zeigt den Ordner `.codex`. Danach startest du mit `codex-modlight`. Der normale Befehl `codex` bleibt, wie er war.

Die Konfigurationen enthalten deinen Modlight-Schlüssel. Leg sie in deinen Benutzerordner, nie in ein Projekt-Repository.
