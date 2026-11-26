# Venice

Venice.ai ist ein zweiter Anbieter neben RunPod. Statt eine Grafikkarte zu mieten und ein Modell darauf zu laden, wählst du ein fertiges Modell aus dem Katalog von Venice. Es antwortet sofort, einen Pod gibt es nicht. Bezahlt wird pro Token, also nur für das, was dein Agent tatsächlich schickt und bekommt. Für den Agenten ändert sich nichts: gleiche Adresse, gleicher Schlüssel, und das Modell heißt so, wie du es in Podlight nennst.

<!-- TODO Screenshot: Venice-Modell in der Modellliste neben einem Pod-Modell (screenshots/de/venice-model.png) -->

## Pod oder Venice?

- **Venice** passt, wenn du ein Modell nur ab und zu brauchst, nicht 10 bis 25 Minuten auf den Start warten willst oder ein großes Modell nutzen möchtest, für das du teure Karten mieten müsstest. Ohne Anfragen kostet es nichts.
- **Ein Pod** passt, wenn du ein bestimmtes Modell von Hugging Face willst, das Venice nicht anbietet, wenn du festlegen willst, in welcher Region es läuft, oder wenn ein Agent stundenlang durcharbeitet. Dann ist ein fester Preis pro Stunde oft günstiger als viele Millionen Token.

Beides lässt sich mischen. Ein Agent kann ein Venice-Modell und ein Pod-Modell nebeneinander nutzen.

## Ein Konto bei Venice

Lege auf venice.ai ein Konto an. Für die API brauchst du Guthaben, ein kostenloses Konto allein reicht nicht.

## Guthaben aufladen

Venice kennt mehrere Arten von Guthaben:

- **USD-Guthaben:** Du lädst es per Karte oder Krypto auf. Es verfällt nicht.
- **Abo-Guthaben:** Die Tarife Pro, Plus und Max enthalten jeden Monat ein Kontingent für die API.
- **DIEM:** Wer DIEM-Token einsetzt (Staking), bekommt pro DIEM etwa 1 USD Guthaben am Tag. Es gilt für diesen Tag und füllt sich am nächsten wieder auf.

Venice zieht in dieser Reihenfolge ab: zuerst DIEM, dann verdientes Guthaben, dann Abo-Guthaben, zuletzt USD. Ist alles aufgebraucht, lehnt Venice Anfragen mit dem Fehler 402 ab.

## API-Key anlegen

- Öffne https://venice.ai/settings/api und klicke auf „Generate New API Key“.
- Als Typ genügt „Inference Only“. Einen Admin-Key braucht Podlight nicht.
- Wenn du willst, gibst du ein Ablaufdatum und ein Tageslimit in USD oder DIEM an. Venice lehnt dann alles ab, was darüber hinausgeht, unabhängig von Podlight.
- Kopiere den Key. Venice zeigt ihn nur dieses eine Mal. Er beginnt mit `VENICE_INFERENCE_KEY_`.

## Den Key in Podlight eintragen

Füge den Key unter Einstellungen → Anbieter → Venice ein, oder gleich bei der Einrichtung, wenn Podlight dort nach Venice fragt. Podlight prüft ihn sofort und zeigt dein Guthaben und deinen Tarif bei Venice. Der Key liegt im Schlüsselbund dieses Macs und geht nur an Venice.

<!-- TODO Screenshot: Einstellungen → Anbieter → Venice mit Guthaben und Tarif (screenshots/de/settings-venice.png) -->

## Ein Venice-Modell hinzufügen

- Klicke unter „Modelle“ auf „Modell hinzufügen“ und wähle „Venice (fertiges Modell, pro Token)“.
- Suche im Katalog nach einem Namen. Filter grenzen die Liste ein: nach Datenschutz (siehe unten) und nach Fähigkeiten wie Werkzeugaufrufen, Bildern, Reasoning und Code. Für Coding-Agenten brauchst du Werkzeugaufrufe.
- Zu jedem Modell stehen der Preis pro 1 Million Token für Eingabe und Ausgabe und die Länge des Kontexts.
- Vergib einen Namen. Unter diesem Namen fragt dein Agent das Modell an.

Damit ist das Modell bereit. Starten musst du es nicht.

<!-- TODO Screenshot: Venice-Katalog mit Filtern und Preisen (screenshots/de/add-venice.png) -->

### Private und Anonymized

Venice teilt seine Modelle in zwei Stufen ein:

- **Private:** Venice betreibt das Modell selbst und speichert weder Anfragen noch Antworten. Dieser Filter ist vorausgewählt.
- **Anonymized:** Modelle anderer Anbieter wie Claude, GPT oder Gemini. Venice leitet die Anfrage weiter und entfernt vorher, was auf dich hinweist, etwa Konto und IP-Adresse. Den Inhalt sieht der Anbieter aber, und für ihn gelten dessen Regeln zur Speicherung.

Schickt dein Agent Code, der nicht nach außen soll, bleib bei „Private“.

## Benutzen

Ein Venice-Modell erreichst du wie jedes andere Modell in Podlight: über die Adresse und den Schlüssel unter „Verbindung“ und den Namen, den du vergeben hast. Das funktioniert mit OpenCode, Codex, Claude Code und jedem Programm, das mit OpenAI spricht. Für Claude Code übersetzt Podlight zwischen der Anthropic-Schnittstelle und der von Venice. Eine bestehende Konfiguration musst du nicht ändern, nur den Modellnamen.

## Kosten und Limits

Podlight zeigt bei jedem Venice-Modell, wie viele Token es verbraucht hat und was das gekostet hat, während der Agent arbeitet. Ein Agent schickt bei jeder Anfrage den bisherigen Verlauf mit. Deshalb zählt meist der Preis für die Eingabe mehr als der für die Ausgabe.

Das Guthaben bei Venice fragt Podlight regelmäßig ab. Der Knopf zum Aktualisieren in der Symbolleiste (⌘R) fragt sofort.

Die Ausgabelimits unter Einstellungen → Allgemein gelten für Pods und Venice zusammen. Ist ein Limit erreicht, schickt Podlight bis zum nächsten Tag oder Monat keine Anfragen mehr an Venice. Das Tageslimit am Key selbst (siehe oben) wirkt zusätzlich, direkt bei Venice.

### Wenn Venice ablehnt

- **Kein Guthaben (Fehler 402):** Lade bei Venice auf. Nutzt du nur DIEM, kommt das Guthaben am nächsten Tag zurück.
- **Limit des Keys erreicht:** Das Tageslimit in USD oder DIEM, das du beim Key eingestellt hast, ist ausgeschöpft. Hebe es auf https://venice.ai/settings/api an oder warte bis zum nächsten Tag.
- **Key abgelaufen oder ungültig:** Lege bei Venice einen neuen Key an und trage ihn unter Einstellungen → Anbieter → Venice ein.
