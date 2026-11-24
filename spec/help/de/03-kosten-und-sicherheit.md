# Kosten und Sicherheit

Ein gemieteter Pod kostet Geld, solange er läuft, auch wenn niemand ihn benutzt. Podlight stoppt ihn deshalb auf mehreren Wegen.

## Jeder Start hat ein Ende

Beim Starten wählst du „Läuft bis“, etwa zwei Stunden oder eine Uhrzeit. Podlight zeigt, was das höchstens kostet. Solange er läuft, kannst du verlängern, im Modell oder im Menü „Modell → Um eine Stunde verlängern“.

![Ein laufendes Modell](screenshots/de/models.png)

## Leerlauf-Stopp

Kommt eine Weile keine Anfrage, stoppt der Pod, standardmäßig nach 30 Minuten. Abschalten lässt sich das nicht, nur die Dauer ändern.

## Notbremse im Pod

In jedem Pod läuft ein kleiner Wächter. Hört er 15 Minuten nichts von Podlight, stoppt er den Pod selbst. Das greift, wenn dein Mac schläft, Podlight abstürzt oder das Netz weg ist. Er benutzt dafür einen Schlüssel, den RunPod in jeden Pod legt und der nur diesen einen Pod steuern kann. Dein eigener API-Key verlässt den Mac nie.

## Ausgabelimits

Unter Einstellungen → Allgemein legst du fest, wie viel Podlight pro Tag und pro Monat ausgeben darf. Ist ein Limit erreicht, stoppt Podlight die Pods und startet sie bis zum nächsten Tag oder Monat nicht wieder, auch nicht auf Anfrage eines Agenten.

![Die Ansicht „Kosten“](screenshots/de/costs.png)

Die Zahlen unter „Kosten“ zählt Podlight selbst: Preis pro Stunde mal Laufzeit, nur für die Pods dieses Macs. Genau abgerechnet wird bei RunPod. „Guthaben bei RunPod“ zeigt, was in deinem RunPod-Konto noch übrig ist und wie lange es bei den aktuellen Kosten des ganzen Kontos pro Stunde reicht, andere Pods eingeschlossen. Unter einem Tag wird die Zeile orange, unter drei Stunden rot.

Der Knopf zum Aktualisieren in der Symbolleiste (⌘R) fragt RunPod und alle Server sofort. Ein Pod, den du in der RunPod-Konsole gelöscht hast, verschwindet aus Podlight ohnehin binnen Sekunden.

## Podlight beenden

Laufen noch Pods, fragt Podlight vor dem Beenden nach. „Stoppen und beenden“ ist die Voreinstellung. Lässt du sie weiterlaufen, erreicht dein Agent sie nicht mehr, und die Notbremse stoppt sie nach der eingestellten Zeit.

Das Fenster zu schließen beendet Podlight nicht. Die App läuft in der Menüleiste weiter, und dein Agent bleibt verbunden.

## Modell zwischenspeichern

Pro Modell entscheidest du, ob es zwischen zwei Läufen auf einer Festplatte bei RunPod bleibt:

- **Aus (Standard):** Am Ende eines Laufs löscht Podlight den Pod. Bis zum nächsten Start kostet nichts. Dafür lädt jeder Start das Modell neu, das dauert 10 bis 25 Minuten.
- **An:** Der Pod wird nur gestoppt und behält seine Festplatte. Der nächste Start dauert etwa eine Minute. RunPod berechnet die Festplatte mit 0,20 USD pro GB und Monat, solange der Pod gestoppt ist, im Betrieb mit 0,10 USD. Abgerechnet wird stundenweise: Bei 30 GB sind das im gestoppten Zustand etwa 0,008 USD pro Stunde oder 6 USD im Monat.

Podlight zeigt diese Kosten pro Stunde und pro Monat beim Anlegen, beim Start und beim Modell. Unter „Kosten“ steht jedes Modell mit dem, was es gerade kostet: im Betrieb GPU und Speicher, gestoppt mit behaltener Festplatte deren Preis, sonst nichts. Podlight rechnet diese Kosten in die Ausgabelimits ein. Pods mit Festplatte, die länger als die eingestellte Frist nicht benutzt wurden (Einstellungen, Standard 3 Tage), löscht Podlight samt Festplatte, vorher nie. Ist beim Fortsetzen die Karte auf dem Rechner des Pods belegt, bleibt der Pod mit seiner Festplatte erhalten. Podlight versucht es dann alle 30 Sekunden erneut, bis zu dem Ende, das du beim Start gewählt hast, und setzt den Pod fort, sobald die Karte frei ist. Das Modell zeigt so lange „Wartet auf eine Karte“. Mit „Warten beenden“ brichst du ab. „Auf neuer Karte starten …“ baut einen neuen Pod und lädt das Modell neu. Der alte Pod und seine Festplatte bleiben, bis der neue antwortet. Scheitert der neue, bleibt der alte erhalten. Den Schalter änderst du unter „Bearbeiten“, solange das Modell gestoppt ist.
