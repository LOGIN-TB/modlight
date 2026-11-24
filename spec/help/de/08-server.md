# Server

Ein Podlight-Server hält deine Modelle für Agenten erreichbar, auch wenn dieser Mac aus ist, etwa für n8n, einen Agenten auf einem anderen Rechner oder ein Team. Er läuft als ein Container auf einem VPS, einem NAS oder mit Coolify. Podlight auf dem Mac steuert ihn: Modelle anlegen, starten, Limits setzen, Zugangsschlüssel vergeben. Laufen muss die App dafür nicht.

![Ein Server in der Übersicht](screenshots/de/overview-server.png)

## Server aufsetzen

Unter „Server hinzufügen …“ → „Wie richte ich einen Server ein?“ steht eine fertige `docker-compose.yml`. Starte sie mit `docker compose up -d`. Nach dem Start schreibt der Server einen Kasten „PODLIGHT-SERVER – VERBINDUNG“ in sein Log (`docker compose logs`, in Coolify unter Logs). Darin stehen die Adresse, die du in Podlight einträgst, und der Kopplungscode. Der Code gilt einmal und 30 Minuten lang, auch über einen Neustart hinweg. `docker exec <container> podlight-code` erzeugt einen neuen, etwa für einen weiteren Mac oder wenn der erste abgelaufen ist (in Coolify im Terminal des Containers).

Die Adresse nimmt der Kasten aus der Domain, die Coolify dem Dienst gibt, oder aus `PUBLIC_URL` bei einem eigenen Reverse Proxy. Ist `HOST_IP` auf die Adresse des Rechners im lokalen Netz gesetzt, steht auch die lokale Adresse dort. Einmal fragt er die öffentliche IP des Servers ab, als Hilfe beim Einrichten einer Domain; `PUBLIC_IP_LOOKUP=false` schaltet das ab. Mit `PODLIGHT_LANG=de` erscheint der Kasten auf Deutsch.

Bevor der Server aus dem Internet erreichbar ist, braucht er eine https-Adresse. In Coolify trägst du dafür eine Domain für den Dienst ein, sonst stellst du einen Reverse Proxy wie Caddy davor. Podlight verbindet sich nur mit https-Adressen. Ausnahmen sind dieser Mac und das lokale Netz, dort warnt Podlight, dass die Verbindung unverschlüsselt ist.

## Koppeln

In der Seitenleiste unter „Podlight“ → „Server hinzufügen …“ gibst du die Adresse und den Kopplungscode ein. Danach erscheint der Server als eigener Abschnitt in der Seitenleiste. Wer nur einen Server nutzt, wählt im Willkommensbildschirm „Ich nutze einen Podlight-Server …“; dieser Mac braucht dann keinen eigenen RunPod-Schlüssel.

Direkt nach dem Koppeln bietet Podlight an, die Einrichtung dieses Macs mitzunehmen: RunPod-API-Schlüssel und Hugging-Face-Token, Ausgabenlimits und Regeln sowie Modelle mit ihren Pods. Ein Modell zieht mit Pod und behaltener Festplatte um, es wird also nichts neu geladen, und ein laufendes läuft weiter. Danach verlässt es diesen Mac. Dasselbe gibt es unter „Server-Einstellungen“ → „Von diesem Mac übernehmen …“ und für ein einzelnes Modell in seinem Kontextmenü unter „An Server übergeben“.

![Von diesem Mac übernehmen](screenshots/de/server-transfer.png)

Der Server bezahlt seine Pods mit dem RunPod-API-Schlüssel. Er liegt verschlüsselt auf dem Server, Podlight auf dem Mac liest ihn nie zurück. Unter „Server-Einstellungen“ kannst du ihn auch dort eintragen oder ändern und die Limits pro Tag und Monat, die Notbremse und den Standard-Standort einstellen.

![Server-Einstellungen](screenshots/de/server-settings.png)

## Modelle auf dem Server

„Modell hinzufügen …“ im Abschnitt des Servers führt durch dieselben Schritte wie auf dem Mac. Die Kartenliste kommt dabei vom Server. Starten, Stoppen und Verlängern funktionieren wie gewohnt. Im Modell steht „Läuft auf“ mit dem Namen des Servers.

## Agenten verbinden

Agenten, die ein Modell über diesen Mac genutzt haben, verbinden sich nach dem Umzug mit dem Server.

Agenten sprechen mit dem Server über einen eigenen Zugangsschlüssel, nicht über den Schlüssel dieses Macs. Unter „Verbindung“ im Abschnitt des Servers legst du mit „Neuer Zugangsschlüssel …“ einen an, am besten einen pro Agent oder Rechner. Ein Schlüssel lässt sich auf einzelne Modelle beschränken. Der Schlüssel wird nur direkt nach dem Anlegen angezeigt. Kopiere ihn dann, der Server speichert nur einen Fingerabdruck.

Mit dem neuen Schlüssel enthalten die Konfigurationsdateien unter „Konfigurationsdateien für Fortgeschrittene“ alles Nötige. Die Funktionen heißen nach dem Server, bei einem Server „Office“ etwa `claude-podlight-office`. So stehen sie neben denen für diesen Mac.

![Verbindung zu einem Server](screenshots/de/server-connection.png)

## Wenn der Mac aus ist

Der Server stoppt Pods nach denselben Regeln wie der Mac: am Ende von „Läuft bis“, nach dem Leerlauf, an den Ausgabenlimits. Ein gestopptes Modell startet von selbst, wenn ein Agent es anfragt, solange die Limits das zulassen.

Fällt der Server aus, stoppt sich jeder seiner Pods nach der eingestellten Zeit selbst (Standard 15 Minuten). Der Server fasst nur Pods an, die er selbst angelegt hat. Pods dieses Macs und andere Pods in deinem RunPod-Konto bleiben unberührt.

Beendest du Podlight auf dem Mac, laufen die Modelle auf dem Server weiter. „Server entfernen …“ in den Server-Einstellungen lässt Podlight den Server vergessen. Die Modelle dort laufen nach den Regeln des Servers weiter.
