# OpenCode verbinden

Podlight stellt auf diesem Mac eine OpenAI-kompatible Adresse bereit: `http://127.0.0.1:7635/v1`. Nur Programme auf diesem Mac erreichen sie, und nur mit dem Podlight-Schlüssel.

## So geht es

- Öffne in Podlight „Verbindung“ und klicke auf „OpenCode-Konfiguration kopieren“.
- Öffne die Datei `~/.config/opencode/opencode.json`. Gibt es sie noch nicht, legst du sie an. „Ordner im Finder öffnen“ bringt dich hin.
- Füge die Konfiguration ein. Steht schon etwas in der Datei, übernimm nur den Eintrag unter `providers`.
- Starte OpenCode und wähle mit `/models` das Modell aus. Es heißt `podlight/<Name>`.

![Die Ansicht „Verbindung“](screenshots/de/connection.png)

Die Konfiguration enthält deinen Podlight-Schlüssel. Lege sie deshalb in deinem Benutzerordner ab und nie in einem Projekt-Repository.

## Was passiert bei der ersten Anfrage

Läuft das Modell gerade nicht, startet Podlight es von selbst und hält die Anfrage fest, bis es antwortet. Ein gestoppter Pod ist nach etwa einer Minute wieder da. Ein ganz neuer Pod braucht bis zu 25 Minuten. Die Konfiguration lässt OpenCode bis zu 10 Minuten warten, starte ein neues Modell deshalb beim ersten Mal in Podlight selbst.

Ein so geweckter Pod hat kein festes Ende. Er stoppt, wenn keine Anfragen mehr kommen (Leerlauf-Stopp), spätestens nach der Höchstlaufzeit von 12 Stunden.

## Andere Programme

Jedes Programm, das eine OpenAI-kompatible Schnittstelle kann, funktioniert ebenso. Unter „Verbindung → Andere Programme“ stehen Adresse, Schlüssel und Modellnamen zum Kopieren.

## Verbindung prüfen

„Verbindung testen“ fragt die Modellliste ab. Kommt „Funktioniert“, ist alles eingerichtet. Ist der Port belegt, wählst du unter Einstellungen → Erweitert einen anderen und trägst ihn in OpenCode nach.
