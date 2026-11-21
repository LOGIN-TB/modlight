# Server

Ein Podlight-Server hält deine Modelle für Agenten erreichbar, auch wenn dieser Mac aus ist, etwa für n8n, einen Agenten auf einem anderen Rechner oder ein Team. Er läuft als ein Container auf einem VPS, einem NAS oder mit Coolify. Podlight auf dem Mac steuert ihn: Modelle anlegen, starten, Limits setzen, Zugangsschlüssel vergeben. Laufen muss die App dafür nicht.

![Ein Server in der Übersicht](screenshots/de/overview-server.png)

## Server aufsetzen

Unter „Server hinzufügen …“ → „Wie richte ich einen Server ein?“ steht eine fertige `docker-compose.yml`. Starte sie mit `docker compose up -d`. Beim ersten Start schreibt der Server einen Kopplungscode in sein Log (`docker compose logs`). Der Code gilt einmal und 30 Minuten lang, auch über einen Neustart hinweg.

Bevor der Server aus dem Internet erreichbar ist, braucht er eine https-Adresse. In Coolify trägst du dafür eine Domain für den Dienst ein, sonst stellst du einen Reverse Proxy wie Caddy davor. Podlight verbindet sich nur mit https-Adressen. Ausnahmen sind dieser Mac und das lokale Netz, dort warnt Podlight, dass die Verbindung unverschlüsselt ist.

## Koppeln

In der Seitenleiste unter „Podlight“ → „Server hinzufügen …“ gibst du die Adresse und den Kopplungscode ein. Danach erscheint der Server als eigener Abschnitt in der Seitenleiste.

Unter „Server-Einstellungen“ trägst du den RunPod-API-Key des Servers ein. Der Server bezahlt seine Pods damit selbst. Der Schlüssel liegt verschlüsselt auf dem Server, Podlight auf dem Mac liest ihn nie zurück. Dort stellst du auch die Limits pro Tag und Monat, die Notbremse und den Standard-Standort ein.

![Server-Einstellungen](screenshots/de/server-settings.png)

## Modelle auf dem Server

„Modell hinzufügen …“ im Abschnitt des Servers führt durch dieselben Schritte wie auf dem Mac. Die Kartenliste kommt dabei vom Server. Starten, Stoppen und Verlängern funktionieren wie gewohnt. Im Modell steht „Läuft auf“ mit dem Namen des Servers.

## Agenten verbinden

Agenten sprechen mit dem Server über einen eigenen Zugangsschlüssel, nicht über den Schlüssel dieses Macs. Unter „Verbindung“ im Abschnitt des Servers legst du mit „Neuer Zugangsschlüssel …“ einen an, am besten einen pro Agent oder Rechner. Ein Schlüssel lässt sich auf einzelne Modelle beschränken. Der Schlüssel wird nur direkt nach dem Anlegen angezeigt. Kopiere ihn dann, der Server speichert nur einen Fingerabdruck.

Mit dem neuen Schlüssel enthalten die Konfigurationsdateien unter „Konfigurationsdateien für Fortgeschrittene“ alles Nötige. Die Funktionen heißen nach dem Server, bei einem Server „Office“ etwa `claude-podlight-office`. So stehen sie neben denen für diesen Mac.

![Verbindung zu einem Server](screenshots/de/server-connection.png)

## Wenn der Mac aus ist

Der Server stoppt Pods nach denselben Regeln wie der Mac: am Ende von „Läuft bis“, nach dem Leerlauf, an den Ausgabenlimits. Ein gestopptes Modell startet von selbst, wenn ein Agent es anfragt, solange die Limits das zulassen.

Fällt der Server aus, stoppt sich jeder seiner Pods nach der eingestellten Zeit selbst (Standard 15 Minuten). Der Server fasst nur Pods an, die er selbst angelegt hat. Pods dieses Macs und andere Pods in deinem RunPod-Konto bleiben unberührt.

Beendest du Podlight auf dem Mac, laufen die Modelle auf dem Server weiter. „Server entfernen …“ in den Server-Einstellungen lässt Podlight den Server vergessen. Die Modelle dort laufen nach den Regeln des Servers weiter.
