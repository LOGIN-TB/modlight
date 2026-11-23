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

## „Starttest fehlgeschlagen“ oder Claude Code meldet „exceeded the 32000 output token maximum“

Nach jedem Start stellt Podlight dem Modell eine kurze Frage. Antwortet es nur mit wiederholten Zeichen wie „!!!!“, stoppt Podlight den Pod sofort. Ein solches Modell hört nie von selbst auf zu schreiben, und Claude Code bricht jede Antwort dann am Längenlimit ab. Ursache ist meist eine fehlerhafte Quantisierung oder ein Rechenkern, der auf dieser Karte falsch rechnet. Nimm eine andere Fassung des Modells, etwa die GGUF-Fassung des Herausgebers, oder eine andere Kartenart.

## „Der RunPod-Rechner konnte seine Karte nicht ansprechen“

Die Engine brach mit einem CUDA-Fehler ab, bevor sie das Modell geladen hat. Das liegt am Rechner bei RunPod, nicht am Modell. Starte mit „Auf neuer Karte starten …“ oder wähle unter „Bearbeiten“ eine andere Kartenart. „Engine-Log anzeigen …“ zeigt die letzten Zeilen der Engine.

## „Die Engine kam beim Laden zehn Minuten nicht voran“

Während des Ladens schaut Podlight, ob sich etwas tut: Die Festplatte füllt sich mit dem Download, das Log der Engine wächst, die Engine belegt Grafikspeicher oder rechnet. Steht all das zehn Minuten still, hängt die Engine, meist an einem abgerissenen Download auf diesem Rechner. Podlight stoppt den Pod dann, statt ihn bis zum gewählten Ende laufen und kosten zu lassen. Starte erneut oder mit „Auf neuer Karte starten …“ auf einem anderen Rechner.
