# Modelle und Grafikkarten

## Welches Modell?

Für Coding-Agenten eignen sich Modelle, die Werkzeugaufrufe beherrschen. Podlight liest das aus der Vorlage des Modells und zeigt es bei der Prüfung an. Ohne diese Fähigkeit kann ein Agent keine Dateien lesen oder Befehle ausführen.

4-Bit-Varianten (AWQ, GPTQ, INT4) brauchen etwa halb so viel Speicher wie die Originale. In einer Messung lief dasselbe 27-Milliarden-Modell auf derselben Karte in 4 Bit mehr als doppelt so schnell und hatte doppelt so viel Platz für Kontext.

Podlight 0.1 betreibt Modelle mit vLLM. GGUF-Dateien (llama.cpp) und MLX-Builds laufen damit nicht. Podlight sagt das bei der Prüfung und schlägt Alternativen vor.

## Sparsam, ausgewogen oder schnell

- **Sparsam** stellt die billigste Karte nach vorn, auf die das Modell passt.
- **Ausgewogen** wählt unter den Karten, die mindestens etwa 15 Token pro Sekunde schaffen, das beste Verhältnis von Tempo zu Preis.
- **Schnell** stellt die schnellste Karte nach vorn.

Das Tempo ist eine Schätzung aus der Speicherbandbreite der Karte. Sie liegt meist unter dem, was tatsächlich erreicht wird.

## Wenn die Karte vergeben ist

Freie Karten sind bei RunPod knapp und wechseln innerhalb von Sekunden. Ist deine Karte beim Start vergeben, probiert Podlight die nächsten aus der Vorschlagsliste, sofern sie den eingestellten Kontext fassen. Danach steht im Modell, welche Karte es geworden ist.

## Kontext

Der Kontext ist die Textmenge, die das Modell auf einmal sieht. Coding-Agenten brauchen viel davon. Podlight rechnet aus, wie viel neben dem Modell auf die Karte passt, und hält einen Sicherheitsabstand ein, damit vLLM nicht erst nach dem Download die Arbeit verweigert.
