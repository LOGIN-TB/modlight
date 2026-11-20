# Erste Schritte

Podlight startet ein Sprachmodell deiner Wahl auf einer gemieteten Grafikkarte bei RunPod. Dein Coding-Agent auf diesem Mac, zum Beispiel OpenCode, spricht dann mit diesem Modell wie mit einem OpenAI-Dienst.

## Was du brauchst

- Ein Konto bei RunPod mit etwas Guthaben. Abgerechnet wird pro Minute, solange ein Pod läuft.
- Einen RunPod-API-Key. Podlight führt dich beim ersten Start dorthin.
- Optional ein Hugging-Face-Token, nur für gesperrte Modelle wie Llama oder Gemma.

## Den RunPod-API-Key anlegen

- Öffne in Podlight die Einrichtung (Hilfe → Einrichtung erneut ausführen) und klicke auf „RunPod-Einstellungen öffnen“.
- Melde dich an. Unter „API Keys“ klickst du auf „Create API Key“ und nennst ihn „Podlight“.
- Wähle die Berechtigung „All“ oder „Restricted“ mit Lese- und Schreibrecht für Pods.
- Kopiere den Key und füge ihn in Podlight ein. RunPod zeigt ihn nur dieses eine Mal.
- „Prüfen und speichern“ testet den Key sofort. Podlight legt ihn im Schlüsselbund dieses Macs ab und schickt ihn nur an RunPod.

![Der Schritt zum API-Key in Podlight](screenshots/de/setup-key.png)

## Das erste Modell

- Klicke unter „Modelle“ auf „Modell hinzufügen“.
- Suche nach einem Namen oder füge einen Link von huggingface.co ein.
- Podlight prüft Format, Größe und ob das Modell Werkzeugaufrufe kann, die Coding-Agenten brauchen. Gibt es eine kleinere 4-Bit-Variante, schlägt Podlight sie vor.
- Wähle, was dir wichtig ist: sparsam, ausgewogen oder schnell. Podlight zeigt passende Karten mit Preis pro Stunde und geschätztem Tempo.
- Vergib einen Namen. Unter diesem Namen fragt dein Agent das Modell an.

Bis hierhin kostet nichts. Erst „Starten“ mietet eine Karte.

## Starten

„Starten“ fragt, wie lange der Pod laufen soll, und zeigt die Kosten bis dahin. Der erste Start lädt das Modell herunter und dauert je nach Größe 3 bis 10 Minuten. Spätere Starts sind schneller, weil der Pod seine Festplatte behält.


![Starten mit „Läuft bis“](screenshots/de/start.png)