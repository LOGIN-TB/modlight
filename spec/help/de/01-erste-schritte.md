# Erste Schritte

Modlight gibt deinem Coding-Agenten auf diesem Mac, zum Beispiel OpenCode, eine Adresse und einen Schlüssel für offene Sprachmodelle, egal wo sie laufen: auf einer gemieteten Grafikkarte bei RunPod, die Modlight startet und wieder stoppt, oder als fertiges Modell bei Venice, abgerechnet pro Token. Der Agent spricht mit jedem Modell wie mit einem OpenAI-Dienst; Modlight leitet die Anfrage weiter und behält die Kosten im Blick.

Diese Seite beginnt mit RunPod. Für Venice gibt es die Seite „Venice“.

## Die Übersicht

Modlight öffnet mit der Übersicht. Oben steht, was gerade läuft und was es pro Stunde kostet, darunter die nächsten Schritte bis zum ersten verbundenen Agenten, die Ausgaben gegen deine Limits, deine Modelle mit „Starten“ und die Adresse für Agenten. Sind alle Schritte erledigt, verschwindet die Liste.

![Die Übersicht](screenshots/de/overview.png)

## Was du brauchst

- Ein Konto bei RunPod mit etwas Guthaben. Abgerechnet wird pro Minute, solange ein Pod läuft.
- Einen RunPod-API-Key. Modlight führt dich beim ersten Start dorthin.
- Optional ein Hugging-Face-Token, nur für gesperrte Modelle wie Llama oder Gemma.

## Den RunPod-API-Key anlegen

- Öffne in Modlight die Einrichtung (Hilfe → Einrichtung erneut ausführen) und klicke auf „RunPod-Einstellungen öffnen“.
- Melde dich an. Unter „API Keys“ klickst du auf „Create API Key“ und nennst ihn „Modlight“.
- Wähle die Berechtigung „All“ oder „Restricted“ mit Lese- und Schreibrecht für Pods.
- Kopiere den Key und füge ihn in Modlight ein. RunPod zeigt ihn nur dieses eine Mal.
- „Prüfen und speichern“ testet den Key sofort. Modlight legt ihn im Schlüsselbund dieses Macs ab und schickt ihn nur an RunPod.

![Der Schritt zum API-Key in Modlight](screenshots/de/setup-key.png)

## Hugging-Face-Token (empfohlen)

Die Einrichtung bietet als zweiten Schritt einen Hugging-Face-Token an. Er ist freiwillig, aber empfohlen: Pods laden Modelle über Adressen, die RunPod mit anderen Kunden teilt, und Hugging Face begrenzt Downloads ohne Konto stärker. Für gesperrte Modelle wie Llama oder Gemma ist er Pflicht. Ein Token mit Leserecht genügt.

## Das erste Modell

- Klicke unter „Modelle“ auf „Modell hinzufügen“.
- Suche nach einem Namen oder füge einen Link von huggingface.co ein.
- Modlight prüft Format, Größe und ob das Modell Werkzeugaufrufe kann, die Coding-Agenten brauchen. Gibt es eine kleinere 4-Bit-Variante, schlägt Modlight sie vor.
- Lege fest, wo der Pod laufen darf (überall, nur EU, EU und EWR, auf Wunsch nur Secure Cloud). Vorbelegt ist, was in den Einstellungen steht; die Wahl gilt nur für dieses Modell.
- Wähle den Kontext und was dir wichtig ist: sparsam, ausgewogen oder schnell. Modlight zeigt, wie viel Kartenspeicher das Modell dafür braucht, und passende Karten mit Preis pro Stunde, geschätztem Tempo und Standort. Änderst du den Kontext, passt sich die Liste an.
- Vergib einen Namen. Unter diesem Namen fragt dein Agent das Modell an.
- Entscheide, ob das Modell zwischengespeichert wird (schneller Neustart, aber Kosten im gestoppten Zustand) oder nicht (Standard).

Bis hierhin kostet nichts. „Hinzufügen und starten“ führt direkt zum Start, „Nur hinzufügen“ legt das Modell an, ohne eine Karte zu mieten.

## Starten

Den Knopf „Starten“ findest du beim Modell direkt unter seinem Status, in der Übersicht und oben rechts in der Symbolleiste. Er fragt, wie lange der Pod laufen soll, und zeigt die Kosten bis dahin. Ein neuer Pod braucht 10 bis 25 Minuten: Der Host bei RunPod lädt zuerst die Engine (etwa 9 GB bei vLLM, 4 GB bei llama.cpp), dann das Modell. Gemessen: 22 Minuten für ein kleines Modell. Einen gestoppten Pod fortzusetzen dauert etwa eine Minute (gemessen: 64 Sekunden), weil er seine Festplatte behält.


![Starten mit „Läuft bis“](screenshots/de/start.png)

## Ohne Pod: Venice

Statt eine Karte zu mieten, kannst du auch ein fertiges Modell von Venice.ai verwenden. Es antwortet sofort und kostet pro Token statt pro Stunde. Dafür brauchst du ein Konto und einen API-Key bei Venice. Wie das geht, steht unter „Venice“.
