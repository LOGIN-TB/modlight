# Messung 2026-11-21: Podlight 0.2 auf echter RunPod-Hardware

> Entstanden unter dem früheren Namen Podlight. · Written under the former name Podlight.

Ausgeführt mit `LiveEUTwoCards` (`apps/mac/PodlightEngine/Tests/PodlightEngineTests/LiveFlowTests.swift`)
über die echte RunPod-API. Geprüft werden sollten drei Dinge aus 0.2: „Nur EU“, ein Lauf ohne
behaltene Festplatte und ein Modell auf zwei Karten (Tensor-Parallel 2). Die Zahlen stammen aus den
Testprotokollen, der Pod-Status aus RunPods eigener API.

## Aufbau
- Modell: `Qwen/Qwen2.5-0.5B-Instruct`. Den KV-Bedarf liest Podlight aus der `config.json`: 12.288 Byte
  pro Token, 14 Attention-Heads (durch 2 teilbar, also für zwei Karten zulässig).
- Hosting „Nur EU“, Image `vllm/vllm-openai:v0.28.0` mit Podlights Startskript, keine Volume-Disk.
- Kartenwahl wie in der App: erst alle Zwei-Karten-Optionen, dann als Ausweichen eine Karte.

## Ergebnisse
| Lauf | Ergebnis |
|---|---|
| 1 | A40 Secure in `EU-SE-1` angelegt, aber mit **einer** Karte. Der Pod war nach 53 s beendet; eine Engine-Ausgabe gab es noch nicht, nach Lauf 3 und 4 war es derselbe Fehler. Der Test hing danach, weil RunPods Log-Stream (`/logs`) nie endet. Der Pod wurde von Hand gefunden und gelöscht (404 bestätigt). |
| 2 | Keine einzige Zwei-Karten-Option in der EU frei; Podlight meldet „keine Kapazität“ mit allen Versuchen. |
| 3, 4 | Ausweichen auf eine RTX 3070 Community. Die Engine brach wieder ab. Podlight las jetzt den Grund über den Watchdog: vLLM verlangte zwei GPUs auf einer. Außerdem meldete der Community-Pod **kein Rechenzentrum**. |
| 5 | Nach den Korrekturen unten: wieder keine Zwei-Karten-Kapazität, Ausweichen auf RTX 2000 Ada Secure, 0,24 $/h, in `EU-RO-1`. **Bereit nach 266 s**, Chat-Anfrage HTTP 200, am Ende gelöscht (RunPod antwortet mit 404). |

## Was dabei gefunden und behoben wurde
- **Ausweichen auf weniger Karten.** Die Umgebungsvariable `PODLIGHT_TP` blieb auf 2, wenn RunPod für
  zwei Karten keinen Platz hatte und Podlight eine Karte nahm. vLLM brach dann mit „World size (2) is
  larger than the number of available GPUs (1)“ ab. Jetzt folgt `PODLIGHT_TP` der tatsächlich
  angelegten Kartenzahl (Test `aFallbackWithFewerCardsTellsTheEngineSo`).
- **Community-Pods melden keinen Standort.** `dataCenterId` blieb bei Community-Pods während des
  ganzen Laufs leer. Mit einer gewählten Region nutzt Podlight deshalb nur noch Secure Cloud, und ein
  Pod ohne gemeldetes Rechenzentrum wird unter einer Region gelöscht. Einstellungen und Hilfe sagen das.
- **Warum die Engine stirbt.** RunPod hebt die Ausgabe eines gestoppten Pods nicht auf. Das Startskript
  schreibt die vLLM-Ausgabe und den Exit-Code jetzt in den Pod, der Watchdog liefert die letzten Zeilen
  unter `/log` und wartet zwei Minuten, bevor er den Pod stoppt. Podlight liest sie, beendet den Pod und
  zeigt den Grund an.
- **Test hing.** `timeoutInterval` von `URLRequest` ist eine Leerlauf-Frist; ein Stream, der ab und zu
  etwas schickt, läuft damit ewig. Der Live-Test nutzt jetzt eine Sitzung mit Gesamtfrist.

## Was diese Messung nicht belegt
- **Zwei Karten in einem Pod laufen live noch nicht nachgewiesen.** In keinem der Läufe hatte RunPod in
  der EU zwei Karten eines Typs frei. Die Rechnung (Speicher × Karten, Teilbarkeit der Heads), die
  Anfrage an RunPod (`gpu.count`) und die Übergabe an vLLM (`--tensor-parallel-size`) sind mit
  Unit-Tests abgedeckt, ein echter Lauf mit `tensor_parallel_size=2` steht aus.
- Ob `HF_XET_HIGH_PERFORMANCE=1` die Downloads beschleunigt, lässt sich bei einem 1-GB-Modell nicht
  messen.

## Weitere Befunde
- `pod.cost` enthält nur die Karten (A40: 0,59 $/h, genau der Listenpreis). Den Speicher rechnet
  Podlight selbst dazu, es zählt also nichts doppelt.
- 266 s bis bereit sind deutlich weniger als die 22 Minuten aus 0.1. Der Host hatte das Image
  vermutlich schon; das bleibt Glückssache und von Podlight aus nicht steuerbar.
- Lokales Netzwerk (Test `LANAccessTests`, auf diesem Mac): Mit „Nur dieser Mac“ antwortet das Gateway
  über die LAN-Adresse nicht. Mit Freigabe antwortet es mit Schlüssel (200), ohne oder mit falschem
  Schlüssel mit 401, und ein falscher Schlüssel kostet eine Sekunde.
