# Wenn etwas nicht klappt

## „RunPod kennt diesen Key nicht“

Der Key wurde nicht vollständig kopiert oder ist widerrufen. Lege bei RunPod einen neuen an und füge ihn unter Einstellungen → Zugänge ein.

## „Keine freie Karte bei RunPod“

Alle passenden Karten waren in dem Moment vergeben. Versuche es nach ein paar Minuten noch einmal oder wähle beim Modell das Ziel „Schnell“, dann kommen mehr Kartentypen in Frage.

## Der Start dauert lange

Ein neuer Pod lädt zuerst die Engine (etwa 9 GB) und dann das Modell. Danach startet vLLM, was allein rund zwei Minuten braucht. Bis zu 25 Minuten sind normal, solange Podlight „Modell wird geladen“ zeigt. Fortsetzen geht schneller, weil der Pod seine Festplatte behält.

## „Das Modell braucht einen Hugging-Face-Token“

Manche Hersteller geben ihre Modelle erst nach Zustimmung frei. Öffne die Modellseite auf huggingface.co, stimme den Bedingungen zu und trage unter Einstellungen → Zugänge einen Token mit Leserecht ein.

## „RunPod hat den Pod außerhalb deiner Region platziert“

RunPod behandelt die gewählte Region nur als Vorgabe. Podlight hat den Pod gelöscht, bevor er etwas beantwortet hat. Starte noch einmal; meist klappt es beim nächsten Versuch. Bleibt es dabei, erlaube unter Einstellungen → Hosting „EU und EWR“ oder schalte „Nur Secure Cloud“ aus.

## OpenCode bekommt keine Antwort

- Prüfe unter „Verbindung“, ob dort „Agenten auf diesem Mac können sich jetzt verbinden“ steht.
- Prüfe, ob der Schlüssel in `opencode.json` noch stimmt. Nach „Neuen Schlüssel erstellen“ muss er dort ersetzt werden.
- Stimmt der Modellname? `/v1/models` liefert die Namen, die Podlight kennt.

## Ein Pod lief weiter, obwohl Podlight zu war

Podlight war beendet, und die Notbremse im Pod stoppt ihn erst nach der eingestellten Zeit ohne Kontakt, standardmäßig 15 Minuten. Beim nächsten Öffnen zeigt Podlight beim Modell an, dass er außerhalb von Podlight gestoppt wurde. Prüfe im Zweifel die RunPod-Konsole: Dort steht verbindlich, welche Pods laufen.
