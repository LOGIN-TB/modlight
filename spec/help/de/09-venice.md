# Venice

Venice.ai ist ein zweiter Anbieter neben RunPod. Statt eine Grafikkarte zu mieten und ein Modell darauf zu laden, wählst du ein fertiges Modell aus dem Katalog von Venice. Es antwortet sofort, einen Pod gibt es nicht. Bezahlt wird pro Token, also nur für das, was dein Agent tatsächlich schickt und bekommt. Für den Agenten ändert sich nichts: gleiche Adresse, gleicher Key, und das Modell heißt so, wie du es in Podlight nennst.

![Ein Venice-Modell in Podlight](screenshots/de/venice-model.png)

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

Füge den Key unter Einstellungen → Anbieter und Zugänge ein, oder gleich bei der Einrichtung, wenn Podlight dort nach Venice fragt. Podlight prüft ihn sofort und zeigt dein Guthaben und deinen Tarif bei Venice. Der Key liegt im Schlüsselbund dieses Macs und geht nur an Venice.

![Der Schritt zum Venice-Key](screenshots/de/setup-venice.png)

## Ein Venice-Modell hinzufügen

- Klicke auf „Modell hinzufügen …“ und wähle oben im Fenster „Fertiges Modell bei Venice · pro Token“.
- Suche im Katalog nach einem Namen. Filter grenzen die Liste ein: nach Datenschutz (siehe unten) und nach Fähigkeiten wie Werkzeugaufrufen, Bildern, Reasoning und Code. Für Coding-Agenten brauchst du Werkzeugaufrufe.
- Zu jedem Modell stehen der Preis pro 1 Million Token für Eingabe und Ausgabe und die Länge des Kontexts.
- Vergib einen Namen. Unter diesem Namen fragt dein Agent das Modell an.

Damit ist das Modell bereit. Starten musst du es nicht.

![Der Venice-Katalog mit Filtern und Preisen](screenshots/de/add-venice.png)

### Privat und Anonymisiert

Venice teilt seine Modelle in zwei Stufen ein:

- **Privat:** Venice betreibt das Modell selbst und speichert weder Anfragen noch Antworten. Nur diese stehen in der Liste, bis du „Anonymisierte einbeziehen“ ankreuzt.
- **Anonymisiert:** Modelle anderer Anbieter wie Claude, GPT oder Gemini. Venice leitet die Anfrage weiter und entfernt vorher, was auf dich hinweist, etwa Konto und IP-Adresse. Den Inhalt sieht der Anbieter aber, und für ihn gelten dessen Regeln zur Speicherung.

Schickt dein Agent Code, der nicht nach außen soll, bleib bei „Privat“.

## Benutzen

Ein Venice-Modell erreichst du wie jedes andere Modell in Podlight: über die Adresse und den Schlüssel unter „Verbindung“ und den Namen, den du vergeben hast. Das funktioniert mit OpenCode, Codex, Claude Code und jedem Programm, das mit OpenAI spricht. Für Claude Code übersetzt Podlight zwischen der Anthropic-Schnittstelle und der von Venice. Eine bestehende Konfiguration musst du nicht ändern, nur den Modellnamen.

## Kosten und Limits

Die Seite eines Venice-Modells zeigt live, was es tut und kostet:

- **Kosten heute** und, solange gearbeitet wird, die Kosten pro Stunde im Moment.
- **Cache-Treffer:** welcher Anteil der Eingabe aus dem Cache von Venice kam. Grün ab 60 %, orange darunter, rot unter 30 %.
- **Schreiben** und **erstes Token:** wie schnell die Antworten kommen, jeweils neben dem Median, den Venice für alle Nutzer dieses Modells misst.
- **Ø Kontext:** wie viel Verlauf ein Agent pro Anfrage schickt.
- **Token pro Minute** der letzten halben Stunde, aufgeteilt in neue Eingabe, Eingabe aus dem Cache und Ausgabe, daneben die **Ratenlimits** von Venice, wie sie die letzte Antwort meldete, das Tageslimit und wie lange das Guthaben bei der aktuellen Rate reicht.
- **Kosten heute nach Stunde.**

![Die Seite eines Venice-Modells](screenshots/de/venice-model.png)

### Cache und Kosten

Ein Agent schickt bei jeder Anfrage den bisherigen Verlauf mit, oft zehntausende Token. Deshalb zählt meist der Preis für die Eingabe mehr als der für die Ausgabe. Liegt der Anfang einer Anfrage schon im Cache von Venice, kostet dieser Teil nur einen Bruchteil, bei vielen Modellen etwa ein Fünftel.

Venice verteilt Anfragen aber auf mehrere Rechner, und ohne Hinweis landet die nächste Anfrage oft auf einem, der den Anfang nicht kennt. Seit 0.12 schickt Podlight deshalb pro Agent und System-Prompt einen festen Cache-Schlüssel (`prompt_cache_key`) mit. Setzt dein Agent selbst einen, bleibt seiner. Unter „Wofür die Kosten heute anfallen“ siehst du, wie sich die Kosten auf neue Eingabe, Cache und Ausgabe verteilen; greift der Cache kaum, schätzt Podlight dort, was der Tag bei 70 % gekostet hätte.

Das Guthaben bei Venice fragt Podlight regelmäßig ab. Der Knopf zum Aktualisieren in der Symbolleiste (⌘R) fragt sofort.

Die Ausgabenlimits unter Einstellungen → Kosten und Sicherheit (oder unter „Kosten“) gelten für Pods und Venice zusammen. Ist ein Limit erreicht, schickt Podlight bis zum nächsten Tag oder Monat keine Anfragen mehr an Venice. Das Tageslimit am Key selbst (siehe oben) wirkt zusätzlich, direkt bei Venice.

### Wenn Venice ablehnt

- **Kein Guthaben (Fehler 402):** Lade bei Venice auf. Nutzt du nur DIEM, kommt das Guthaben am nächsten Tag zurück.
- **Limit des Keys erreicht:** Das Tageslimit in USD oder DIEM, das du beim Key eingestellt hast, ist ausgeschöpft. Hebe es auf https://venice.ai/settings/api an oder warte bis zum nächsten Tag.
- **Key abgelaufen oder ungültig:** Lege bei Venice einen neuen Key an und trage ihn unter Einstellungen → Anbieter und Zugänge ein.
