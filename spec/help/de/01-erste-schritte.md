# Erste Schritte

Podlight startet ein Sprachmodell deiner Wahl auf einer gemieteten Grafikkarte bei RunPod. Dein Coding-Agent auf diesem Mac, zum Beispiel OpenCode, spricht dann mit diesem Modell wie mit einem OpenAI-Dienst.

## Die Übersicht

Podlight öffnet mit der Übersicht. Oben steht, was gerade läuft und was es pro Stunde kostet, darunter die nächsten Schritte bis zum ersten verbundenen Agenten, die Ausgaben gegen deine Limits, deine Modelle mit „Starten“ und die Adresse für Agenten. Sind alle Schritte erledigt, verschwindet die Liste.

![Die Übersicht](screenshots/de/overview.png)

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

## Hugging-Face-Token (empfohlen)

Die Einrichtung bietet als zweiten Schritt einen Hugging-Face-Token an. Er ist freiwillig, aber empfohlen: Pods laden Modelle über Adressen, die RunPod mit anderen Kunden teilt, und Hugging Face begrenzt Downloads ohne Konto stärker. Für gesperrte Modelle wie Llama oder Gemma ist er Pflicht. Ein Token mit Leserecht genügt.

## Das erste Modell

- Klicke unter „Modelle“ auf „Modell hinzufügen“.
- Suche nach einem Namen oder füge einen Link von huggingface.co ein.
- Podlight prüft Format, Größe und ob das Modell Werkzeugaufrufe kann, die Coding-Agenten brauchen. Gibt es eine kleinere 4-Bit-Variante, schlägt Podlight sie vor.
- Lege fest, wo der Pod laufen darf (überall, nur EU, EU und EWR, auf Wunsch nur Secure Cloud). Vorbelegt ist, was in den Einstellungen steht; die Wahl gilt nur für dieses Modell.
- Wähle den Kontext und was dir wichtig ist: sparsam, ausgewogen oder schnell. Podlight zeigt, wie viel Kartenspeicher das Modell dafür braucht, und passende Karten mit Preis pro Stunde, geschätztem Tempo und Standort. Änderst du den Kontext, passt sich die Liste an.
- Vergib einen Namen. Unter diesem Namen fragt dein Agent das Modell an.
- Entscheide, ob das Modell zwischengespeichert wird (schneller Neustart, aber Kosten im gestoppten Zustand) oder nicht (Standard).

Bis hierhin kostet nichts. „Hinzufügen und starten“ führt direkt zum Start, „Nur hinzufügen“ legt das Modell an, ohne eine Karte zu mieten.

## Starten

Den Knopf „Starten“ findest du beim Modell direkt unter seinem Status, in der Übersicht und oben rechts in der Symbolleiste. Er fragt, wie lange der Pod laufen soll, und zeigt die Kosten bis dahin. Ein neuer Pod braucht 10 bis 25 Minuten: Der Host bei RunPod lädt zuerst die Engine (etwa 9 GB bei vLLM, 4 GB bei llama.cpp), dann das Modell. Gemessen: 22 Minuten für ein kleines Modell. Einen gestoppten Pod fortzusetzen dauert etwa eine Minute (gemessen: 64 Sekunden), weil er seine Festplatte behält.


![Starten mit „Läuft bis“](screenshots/de/start.png)