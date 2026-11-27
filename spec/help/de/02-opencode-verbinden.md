# Agent verbinden

Modlight stellt eine OpenAI-kompatible Adresse bereit. Jeder Coding-Agent, der einen eigenen oder OpenAI-kompatiblen Anbieter erlaubt, kann sie nutzen: OpenCode, Cline, Aider, pi und andere.

## Drei Werte

Unter „Verbindung“ stehen die drei Werte, die jeder Agent braucht, jeweils mit „Kopieren“:

- **Adresse:** auf diesem Mac `http://127.0.0.1:7635/v1`. Ist das lokale Netzwerk freigegeben, steht dort zusätzlich die Adresse für andere Rechner.
- **API-Key:** dein Modlight-Schlüssel. Ohne ihn lehnt Modlight jede Anfrage ab.
- **Modell:** der Name, den du beim Anlegen vergeben hast.

![Die Ansicht „Verbindung“](screenshots/de/connection.png)

Wähle im Agenten einen eigenen bzw. OpenAI-kompatiblen Anbieter und trage die drei Werte ein. „Verbindung testen“ zeigt, ob Modlight antwortet.

## Konfigurationsdateien für Fortgeschrittene

Manche Agenten erwarten eine Datei statt einer Eingabemaske. Unter „Konfigurationsdateien für Fortgeschrittene“ erzeugt Modlight sie fertig:

- **OpenCode:** `~/.config/opencode/opencode.json`. Das Modell heißt dort `modlight/<Name>` und wird mit `/models` gewählt.
- **pi:** `~/.pi/agent/models.json`. Das Modell wird mit `/model` gewählt.
- **Claude Code** und **Codex:** ein Befehl bzw. eine Funktion für das Terminal, siehe „Claude Code und Codex“.
- **Umgebungsvariablen:** `OPENAI_BASE_URL` und `OPENAI_API_KEY`, etwa für Aider.

Steht in der Datei schon etwas, übernimm nur den Eintrag unter `providers`. Die Dateien enthalten deinen Modlight-Schlüssel. Lege sie deshalb in deinem Benutzerordner ab und nie in einem Projekt-Repository.

## Was bei der ersten Anfrage passiert

Läuft das Modell gerade nicht, startet Modlight es von selbst und hält die Anfrage fest, bis es antwortet. Ein gestoppter Pod mit zwischengespeichertem Modell ist nach etwa einer Minute wieder da. Ein ganz neuer Pod braucht bis zu 25 Minuten. Starte ein neues Modell deshalb beim ersten Mal in Modlight selbst.

Ein so geweckter Pod hat kein festes Ende. Er stoppt, wenn keine Anfragen mehr kommen (Leerlauf-Stopp), spätestens nach der Höchstlaufzeit von 12 Stunden.
