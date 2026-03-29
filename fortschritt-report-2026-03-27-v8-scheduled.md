# Fortschrittsbericht — 2026-03-27 (Scheduled v8)

## Systemzustand: STALLED — Eingriff notwendig

Das System steht seit über 43 Stunden effektiv still. Die Worker-Prozesse laufen (status.txt zeigt `state=idle, waiting_for_tasks=1`), aber es werden keine Tasks dispatched. Hier die Analyse und Empfehlungen.

---

## 1. Kernproblem: Queue-Mismatch (5. Wiederkehr)

Das wiederkehrende Hauptproblem besteht weiterhin: Die Worker lesen aus `queues/codex-agent-system.txt`, aber die Task-Einträge landen primär in `codex-queue/codex-agent-system.txt`.

**Aktueller Zustand:**
- `queues/codex-agent-system.txt`: 2 Einträge (task-131, task-132) — **task-130 fehlt**
- `codex-queue/codex-agent-system.txt`: 3 Einträge (task-130, task-131, task-132) — vollständig

Der in v30 dokumentierte "queue-sync guard" in `strategy-loop.sh` existiert (1 Treffer im Code), hat aber offensichtlich task-130 nicht korrekt synchronisiert. Das bedeutet: Der Guard kopiert nicht zuverlässig alle Einträge.

**Zusätzlich:** `pipeline_stale=true` seit 2026-03-26T12:17:56Z — über 43 Stunden. Das CLAUDE.md behauptet "UNBLOCKED (v30)", was nicht der Realität entspricht.

## 2. Metriken-Zusammenfassung

| Metrik | Wert | Bewertung |
|---|---|---|
| Gesamterfolgsrate | 15% | Niedrig |
| Letzte 50 Tasks | 28% | Steigend |
| Letzte 20 Tasks | 10% | **Regression** |
| Timeout-Rate | 37% | Hoch |
| Zombie-Tasks | 18 | Ressourcenverschwendung |
| Registry-Tasks | 20 (12 shelved, 3 failed, 1 completed) | Sehr wenig aktive Tasks |
| Laufende Tasks | 0 | System steht |
| Pipeline stale seit | 43+ Stunden | Kritisch |

## 3. Sind die aktuellen Tasks umsetzbar?

### task-130: "Improve first-pass success rate" (Priority 7, critical)
- **Ziel:** planner.sh — Prompt-Qualität verbessern, Kontext reduzieren
- **Bewertung: UMSETZBAR**, aber fehlt in der Live-Queue. Gut abgegrenzt (1 Datei). Provider: claude.
- **Problem:** Wird nicht dispatched wegen Queue-Mismatch.

### task-131: "Break retry churn" (Priority 6, high)
- **Ziel:** orchestrator.sh — Exponential backoff, identische Fehler überspringen
- **Bewertung: UMSETZBAR.** In Live-Queue vorhanden. Klar abgegrenzt (1 Datei). Provider: claude.
- **Problem:** System dispatched trotzdem nicht (idle + waiting_for_tasks).

### task-132: "Reduce strategy saturation" (Priority 4, medium)
- **Ziel:** strategy-loop.sh — Generierungs-Cooldown, Duplikat-Pruning
- **Bewertung: UMSETZBAR.** In Live-Queue vorhanden. 1 Datei. Provider: claude.

### task-133: "Improve retry success rate" (pending_approval)
- **Bewertung:** Wartet auf Genehmigung. Kann erst nach Approval dispatched werden.

**Fazit Tasks:** Die 3 queued Tasks sind inhaltlich sinnvoll und gut dimensioniert (je 1 Datei, klares Scope). Sie sollten funktionieren — wenn sie dispatched werden.

## 4. Warum steigt die Success Rate nicht?

Drei Ursachen:

1. **Kein Durchsatz:** Seit 3+ Tagen wurde kein einziger Task ausgeführt. Die Queue-Tasks (130-132) sind seit 2026-03-24 queued. Ohne Ausführung keine Verbesserung.

2. **Timeout-Dominanz:** 37% aller historischen Failures sind Timeouts. Die letzten 20 Tasks zeigen 8/10 Timeouts (komplexe Superheld-Tasks mit iOS/Android-SDKs). Diese Tasks hätten als `missing_environment` klassifiziert werden sollen.

3. **Dokumentation vs. Realität divergiert:** CLAUDE.md dokumentiert Fixes die nicht tatsächlich wirken (Queue-Sync "fixed" in v23, v24, v29, v30 — immer noch kaputt). Das System "lernt" Regeln, setzt sie aber nicht nachhaltig um.

## 5. Empfohlene Maßnahmen

### Sofort (Kritisch)
1. **Queue manuell synchronisieren:** Alle 3 Einträge aus `codex-queue/codex-agent-system.txt` nach `queues/codex-agent-system.txt` kopieren. Verifizieren dass task-130 enthalten ist.
2. **pipeline_stale auf false setzen** in metrics.json.
3. **Worker-Prozess prüfen:** `status.txt` zeigt `waiting_for_tasks=1` obwohl die Queue 2 Einträge hat. Der Worker erkennt die Einträge möglicherweise nicht. Logfiles in `codex-logs/` prüfen.

### Kurzfristig (Diese Woche)
4. **Queue-Architektur vereinfachen:** Die duale Queue-Struktur (`queues/` vs `codex-queue/`) ist die Hauptursache für wiederkehrende Stalls. Empfehlung: **Ein einziges Verzeichnis** für alles. Die Trennung von "JSON storage" und "dispatch txt" in verschiedene Ordner erzeugt ständig Inkonsistenzen.
5. **task-133 genehmigen oder shelven** — pending_approval seit Tagen blockiert einen Slot.

### Mittelfristig (Systemisch)
6. **Timeout-Tasks proaktiver ablehnen:** Die Learned Rule für `missing_environment` existiert, wird aber bei komplexen Tasks nicht konsequent angewandt. Ein Pre-Flight-Check vor dem Queuing (nicht erst beim Planner) würde die Timeout-Rate drastisch senken.
7. **Metrics-Pipeline automatisch testen:** Ein einfacher Healthcheck-Cronjob der `queues/*.txt` Zeilen gegen Registry-Status abgleicht und bei Mismatch einen Alert setzt.

## 6. Gesamtbewertung

Das System hat sich konzeptionell verbessert (Rule-Konsolidierung 22→12, Provider-Routing, Zombie-Guard). Aber es leidet an einem strukturellen Infrastruktur-Problem: **Die Queue-Architektur ist fragil und führt wiederholt zu mehrtägigen Stillständen.** Solange dieses Problem nicht durch eine architektonische Vereinfachung gelöst wird (nicht durch wiederholte manuelle Copies), wird das System weiterhin stallen.

Die Success Rate kann nicht steigen wenn keine Tasks ausgeführt werden. Die 3 aktuellen Tasks (130-132) sind sinnvoll und gut dimensioniert — sie müssen nur tatsächlich dispatched werden.

**Priorität:** Queue-Architektur vereinfachen > Tasks dispatchen > Success Rate messen.
