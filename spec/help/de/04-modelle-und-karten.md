# Modelle und Grafikkarten

## Welches Modell?

Für Coding-Agenten eignen sich Modelle, die Werkzeugaufrufe beherrschen. Podlight liest das aus der Vorlage des Modells und zeigt es bei der Prüfung an. Ohne diese Fähigkeit kann ein Agent keine Dateien lesen oder Befehle ausführen.

4-Bit-Varianten (AWQ, GPTQ, NVFP4 oder GGUF in Q4) brauchen etwa halb so viel Speicher wie die Originale. In einer Messung lief dasselbe 27-Milliarden-Modell auf derselben Karte in 4 Bit mehr als doppelt so schnell und hatte doppelt so viel Platz für Kontext.

## GGUF-Modelle

Viele Modelle gibt es bei Hugging Face nur als GGUF. Podlight betreibt sie mit llama.cpp, alle anderen Formate mit vLLM. Welche Engine es wird, entscheidet Podlight selbst nach dem Format.

Ein GGUF-Repository enthält das Modell meist in vielen Quantisierungen, etwa Q4_K_M, Q8_0 oder BF16. Bei der Prüfung wählst du eine aus; Podlight schlägt Q4_K_M vor, die Standardwahl von llama.cpp. Als Faustregel: 4 Bit brauchen halb so viel Speicher wie 8 Bit und verlieren dabei wenig. Unter 4 Bit (Q2, Q3) werden Modelle beim Programmieren und bei Werkzeugaufrufen merklich schlechter. Q8_0 und BF16 liegen nah am Original, brauchen aber doppelt bis viermal so viel Speicher.

Wie viel Speicher ein Token braucht, liest Podlight aus dem Kopf der GGUF-Datei, ohne das Modell herunterzuladen. Die Engine von llama.cpp ist mit etwa 4 GB deutlich kleiner als die von vLLM, ein neuer Pod ist darum oft schneller bereit. MLX-Builds laufen nur auf Apple-Chips und nicht bei RunPod.

## Sparsam, ausgewogen oder schnell

- **Sparsam** stellt die billigste Karte nach vorn, auf die das Modell passt.
- **Ausgewogen** wählt unter den Karten, die mindestens etwa 15 Token pro Sekunde schaffen, das beste Verhältnis von Tempo zu Preis.
- **Schnell** stellt die schnellste Karte nach vorn.

Das Tempo ist eine Schätzung aus der Speicherbandbreite der Karte. Sie liegt meist unter dem, was tatsächlich erreicht wird.

## Wenn die Karte vergeben ist

Freie Karten sind bei RunPod knapp und wechseln innerhalb von Sekunden. Ist deine Karte beim Start vergeben, probiert Podlight die nächsten aus der Vorschlagsliste, sofern sie den eingestellten Kontext fassen. Danach steht im Modell, welche Karte es geworden ist, in Orange, wenn sie mehr kostet als deine.

Ein Ersatz darf höchstens 50 % mehr kosten als deine Karte; einstellbar unter Einstellungen → „Andere Karte darf mehr kosten“ (für einen Server in seinen Server-Einstellungen). Darüber bucht Podlight nichts:

- **Von Hand gestartet:** Das Start-Fenster sagt, dass deine Karte belegt ist, und listet die freien, teureren Karten mit Preis und Aufschlag. Starte auf einer davon oder lass Podlight warten.
- **Warten:** Podlight versucht es bis zum Ende des Laufs alle 30 Sekunden mit Karten im Preisrahmen und startet dann von selbst. Die Seite des Modells zeigt „Wartet auf eine Karte“ und die günstigste freie Karte, die du weiterhin wählen kannst. „Warten beenden“ bricht ab.
- **Von einem Agenten geweckt oder vom Server gestartet:** Niemand kann gefragt werden, also wartet Podlight eine halbe Stunde, ohne die teurere Karte zu buchen. Der Agent bekommt eine Fehlermeldung mit dem Grund.

![Der Start fragt vor einer teureren Karte](screenshots/de/start-price.png)

## Kontext

Der Kontext ist die Textmenge, die das Modell auf einmal sieht. Coding-Agenten brauchen viel davon. Beim Anlegen wählst du ihn zuerst, bis zum Maximum des Modells, also auch 256.000 oder 1 Million Token. Danach zeigt Podlight nur Karten, die ihn fassen.

Wie viel Speicher ein Token braucht, liest Podlight aus der Konfiguration des Modells. Kleine Modelle brauchen pro Token deutlich weniger als große, darum passen bei ihnen sehr lange Kontexte auch auf kleinere Karten. Podlight hält einen Sicherheitsabstand ein, damit vLLM nicht erst nach dem Download die Arbeit verweigert.

## Mehrere Karten

Passt ein langer Kontext nicht auf eine einzelne Karte, schlägt Podlight 2, 4 oder 8 Karten in einem Pod vor, etwa „2 × L40S“. vLLM verteilt das Modell dann auf alle Karten und wird dadurch auch schneller. llama.cpp verteilt die Schichten des Modells auf die Karten: Das bringt mehr Platz, bei einer einzelnen Anfrage aber kein höheres Tempo. Der Preis gilt für alle Karten zusammen. Mehrere gleiche Karten gleichzeitig frei zu bekommen ist bei RunPod schwerer; Podlight probiert notfalls die nächsten Vorschläge.

## Auslastung

Solange ein Modell läuft, zeigt seine Seite unter „Auslastung“, was der Pod gerade tut:
- **Ringe** für GPU-Last, belegten Grafikspeicher (VRAM), CPU, Arbeitsspeicher und Festplatten, bei mehreren Karten für jede einzeln. Arbeitsspeicher und Festplatten werden ab 85 % orange und ab 95 % rot.
- **Kacheln mit den Werten der Engine:**
  - **Schreiben** und **Lesen:** Token pro Sekunde beim Antworten und beim Einlesen des Prompts, gemessen an den letzten Anfragen. Zwischen Anfragen bleibt der letzte Wert stehen.
  - **Prompt-Cache:** welcher Anteil der Prompt-Tokens aus dem Cache kam, statt neu gelesen zu werden. Agenten wie Claude Code schicken bei jeder Anfrage den ganzen bisherigen Verlauf; ein hoher Wert macht die Antworten schnell.
  - **Anfragen** (laufend und wartend), bei vLLM der **Kontext-Cache**, **Seit dem Start** (gelesene und geschriebene Tokens) und die **Karte** mit Temperatur und Leistung.
- **Verlauf** der letzten 30 Minuten.

In der Modellliste, der Übersicht und der Menüleiste steht die GPU-Last neben jedem laufenden Modell.

Gemessen wird im Pod selbst, etwa alle 10 Sekunden, weil RunPods Schnittstelle den belegten Grafikspeicher nicht meldet. Dass vLLM fast den ganzen Grafikspeicher belegt, ist normal: Es reserviert ihn beim Start für den Kontext-Cache. Ob das Modell arbeitet, zeigen GPU-Last und Token pro Sekunde.

Pods, die eine frühere Podlight-Version angelegt hat, melden keine Auslastung, auch wenn sie mit „Modell zwischenspeichern“ fortgesetzt werden. Die Werte erscheinen, sobald das Modell auf einem neuen Pod startet.

## Auf mehreren Macs

Ein Modell gehört dem Mac, auf dem du es angelegt hast. Podlight legt jedes Modell zusätzlich in deinem RunPod-Konto ab, unsichtbar und kostenlos. Ein zweiter Mac mit demselben RunPod-Key zeigt deshalb in der Übersicht unter „Von anderen Macs“ alle Modelle des ersten, laufende und gestoppte. Er sucht jede Minute danach, sofort mit dem Pfeil neben der Überschrift.

„Starten …“ holt ein gestopptes Modell auf diesen Mac und fragt dann, wie lange es laufen soll. „Übernehmen“ holt es, ohne es zu starten. Ab dann startet, stoppt und berechnet es dieser Mac, und deine Agenten verbinden sich mit ihm.

Der erste Mac gibt das Modell innerhalb einer Minute ab, oder sobald er das nächste Mal läuft. Bei ihm steht dann „Verwaltet von …“. Er lässt das Modell in Ruhe, und Anfragen seiner Agenten an dieses Modell bekommen den Hinweis, den anderen Mac zu nutzen. Mit „Zurückholen“ holst du es wieder zu ihm. Löschen entfernt ein abgegebenes Modell nur von diesem Mac.

Beide Macs brauchen Podlight 0.7 oder neuer. Modelle eines Macs mit einer älteren Version erscheinen nur, solange sie einen Pod haben. Sollen mehrere Rechner dieselben Modelle gleichzeitig nutzen, ist ein Podlight-Server der passende Weg.
