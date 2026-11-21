# Standort und Netzwerk

## Wo deine Pods laufen

Unter Einstellungen → Hosting legst du fest, wo Podlight Pods anlegen darf:

- **Überall:** jedes Rechenzentrum von RunPod. Die größte Auswahl an Karten.
- **Nur EU:** Rechenzentren in der EU, derzeit in Rumänien, Schweden, den Niederlanden, Tschechien und Frankreich.
- **EU und EWR:** zusätzlich Island und Norwegen.
- **Nur Secure Cloud:** zertifizierte Rechenzentren statt Community-Rechnern. RunPod nennt dafür SOC 2, ISO 27001 und PCI DSS. Meist etwas teurer.

Mit „Nur EU“ oder „EU und EWR“ nutzt Podlight nur Secure Cloud: Community-Rechner melden keinen Standort, er ließe sich also nicht prüfen.

RunPod behandelt die gewünschten Rechenzentren nur als Vorgabe. Podlight prüft deshalb nach jedem Start, wo der Pod tatsächlich gelandet ist. Liegt er außerhalb, löscht Podlight ihn sofort, bevor er eine Anfrage beantwortet, und sagt dir Bescheid.

Für die DSGVO bietet RunPod einen Auftragsverarbeitungsvertrag mit Standardvertragsklauseln an (runpod.io/legal/data-processing-agreement). Einen festen Datenstandort sichert RunPod darin nicht zu. Ob das für deinen Einsatz genügt, musst du selbst bewerten.

## Zugriff aus dem lokalen Netzwerk

Unter Einstellungen → Netzwerk wählst du, wer sich verbinden darf:

- **Nur dieser Mac:** Standard. Nur Programme auf diesem Mac erreichen Podlight.
- **Dieser Mac und das lokale Netzwerk:** Auch andere Rechner im selben Netz können deine Modelle nutzen. Unter „Verbindung“ stehen dann die Adresse mit dem Namen deines Macs (`<Name>.local`) und seiner IP.

Auch aus dem Netzwerk braucht jede Anfrage deinen Podlight-Schlüssel. Falsche Schlüssel bremst Podlight aus. Die Verbindung im lokalen Netz ist aber nicht verschlüsselt. Gib sie deshalb nur in Netzen frei, denen du vertraust, nicht im öffentlichen WLAN. Beim ersten Mal fragt macOS eventuell, ob Podlight eingehende Verbindungen annehmen darf.
