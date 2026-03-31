# Fortschrittsbericht — 30. März 2026, v5 (Scheduled)

## Systemstatus: DEADLOCK — unverändert seit ~6 Tagen

Die Pipeline steht weiterhin still. Seit dem letzten Bericht (v4, ebenfalls heute) hat sich der Zustand nicht verändert. Das System läuft technisch, produziert aber keinen produktiven Output.

---

## Kennzahlen

| Metrik | Wert | Bewertung |
|---|---|---|
| Gesamttasks (Archiv) | 1.103 | stabil, kein Wachstum |
| Completed | 200 (18,1%) | keine Veränderung |
| Failed | 406 (36,8%) | keine Veränderung |
| Shelved | 375 (34,0%) | keine Veränderung |
| All-time Success Rate | 15% | stagnierend |
| Recent-50 Success Rate | 26% | besser als Schnitt, aber veraltet |
| Last-30 Resolved | 0/30 (0%) | **alarmierend** — nur shelved/failed |
| First-Pass Rate | 57% (4/7 Tasks) | gut, aber winzige Basis |
| Timeout-Rate | 34% (global), 45% (superheld) | kritisch |
| Aktive Registry | 11 Tasks: 4 completed, 7 shelved | **0 offene Tasks** |
| Queue | **leer** | Pipeline-Starvation |
| Aktive Alerts | retry_churn (high), loop_effort (warning) | unverändert |

---

## Sind die bisherigen Tasks umsetzbar?

### Teilweise ja — nur eng fokussierte Tasks funktionieren

Die 4 erfolgreich abgeschlossenen Tasks in der aktiven Registry zeigen das Erfolgsrezept: ein File, ein konkreter Anker, ein klarer erwarteter Outcome. Solche Tasks schaffen 50–64% Success Rate.

### Was systematisch scheitert

Die letzten 30 archivierten Tasks sind ausnahmslos gescheitert — davon 23× der identische "Inventory current decision path" Task (shelved) und 6× "recover stale pipeline" (shelved). Das System generiert repetitiv abstrakte Meta-Tasks, die nie zu konkretem Output führen.

Kategorien mit dauerhaft 0% Success Rate über dutzende Versuche: ux (0/52), security (0/24), architecture (0/12), backend (0/12), auth (0/8), code_quality im Archiv (0/10), documentation (0/4), localization (0/4).

**Funktionierende Kategorien**: research (67%), accessibility (67%), quality (50%), ops (50%), privacy (50%), distribution (50%), privacy_legal/funding/release/legal/build/governance (100%, aber je nur 4–8 Tasks).

---

## Heben wir die Success Rate?

**Nein.** Der Trend zeigt -1.0pp zwischen erster und zweiter Hälfte. Die letzten 30 aufgelösten Tasks haben eine 0% Success Rate. Das System ist nicht nur nicht besser geworden — die jüngste Phase ist die schlechteste.

Der Rule-Set afdc1a2d erreichte 63,6% auf 11 Tasks (bester), der aktuelle 422daf81 liegt bei 50% auf 12 Tasks. Die Rules selbst sind brauchbar, aber es kommen keine passenden Tasks nach.

---

## Root-Cause-Analyse: Warum steht alles?

### 1. DEADLOCK-Zyklus (KRITISCH)

```
Claude-Provider defekt → Self-Improve-Analyzer scheitert
  → Keine automatische Task-Generierung
    → Queue leer → Keine Arbeit
      → Keine neuen Metriken → Gating blockiert
        → Queue bleibt leer (Teufelskreis)
```

### 2. Gating-Blockade `external_control_plane_task`

Die Self-Improve-Logik erkennt 3 Improvement-Opportunities, blocked aber alle 3 mit `external_control_plane_task`. `blocked_analysis: 3, generated: 0, submitted: 0`. Das System wartet auf externen Input, der nicht kommt.

### 3. Repetitive Task-Generierung

23× "Inventory current decision path for improve first-pass success rate" + 6× "recover stale pipeline" = 29 der letzten 30 Tasks sind identische, nutzlose Meta-Tasks. Der Titel-Dedup/Family-Filter greift nicht.

### 4. Retry-Churn aktiv

Alert retry_churn (severity: high) ist aktiv. 41,5% der Retries scheitern an Reviewer-Rejections. 30% sind Timeouts. 90% der superheld-Timeouts sind Zero-Step-Timeouts (Planner verbraucht gesamtes Budget).

---

## Empfohlene Modifikationen

### SOFORT (Deadlock brechen — manueller Eingriff nötig)

1. **Claude-Provider reparieren oder umrouten** — `claude print failed` tritt 2.029× auf. In `codex-learning/provider-routing.json` die Kategorien `infra`, `learning` und `ui` (die auf `claude` geroutet sind) testweise auf `codex` umstellen. Die Success-Rates beider Provider sind in diesen Kategorien nahezu identisch (~8–15%), also kein Qualitätsverlust.

2. **Gating `external_control_plane_task` deaktivieren** — In `codex-learning/self-improve-run.json` oder dem entsprechenden Gating-Code die Blockade aufheben, damit erkannte Improvements submitted werden können. Ohne dies bleibt die Pipeline dauerhaft idle.

3. **3–5 einfache Tasks manuell einspeisen** — Bewährte Typen:
   - `testing`: Unit-Tests für bestehende Funktionen (40% Success Rate)
   - `code_quality`: Kommentare, kleine Refactors (50% bei codex)
   - `stability`: Eng gefasste Guards, einzelne Datei

### KURZFRISTIG (Strukturverbesserungen)

4. **0%-Kategorien blacklisten** — ux, security, architecture, backend, auth, documentation, localization, analytics, modernization, data aus Task-Generierung ausschließen. Das spart ~200 verbrannte Versuche.

5. **Repetitive-Task-Filter verschärfen** — 23× identischer Task ist inakzeptabel. Family-Filter muss auf Titel-Prefix matchen, nicht nur exakten Titel.

6. **Planning-Budget-Cap enforced** — 227 Zero-Step-Timeouts zeigen, dass das 60s-Cap aus CLAUDE.md nicht aktiv durchgesetzt wird. Besonders im superheld-Projekt (90% Zero-Step-Rate).

7. **Reviewer-Strictness reduzieren** — 41,5% Reviewer-Rejections ist zu hoch. Entweder Reviewer-Threshold lockern oder Task-Formulierungen enger vorstrukturieren.

### MITTELFRISTIG (Optimierungen)

8. **Rule-Set afdc1a2d evaluieren** — Bester gemessener Rule-Set (63,6%). Prüfen ob Rückkehr möglich ist.

9. **Priority-Kalibrierung** — priority.json überschätzt Success-Rates. Auf beobachtete Werte zurücksetzen.

10. **Archive-Compaction** — 4,2 MB tasks-archive.json. Abgeschlossene und shelved Tasks älter als 14 Tage in Cold-Archive verschieben.

---

## Zusammenfassung

| Frage | Antwort |
|---|---|
| Aktueller Fortschritt? | **Stillstand** — 0 offene Tasks, Queue leer, Pipeline idle seit ~6 Tagen |
| Tasks umsetzbar? | **Nur eng fokussierte** — 1 File, 1 Anker, klarer Outcome (50–64%); alles andere scheitert |
| Success Rate steigend? | **Nein** — Last-30: 0%, All-time: 15%, kein Aufwärtstrend |
| Modifikationen nötig? | **Ja, dringend** — Provider-Fix, Gating-Blockade lösen, manuelle Task-Einspeisung |

**Prognose**: Ohne manuellen Eingriff in die drei Deadlock-Ursachen (Provider, Gating, leere Queue) wird sich nichts ändern. Das System hat sich in einen stabilen Stillstand manövriert. Die Lernregeln und Execution-Pipeline funktionieren prinzipiell — es fehlt der Input. Der wichtigste einzelne Schritt bleibt die Reparatur/Umroutung des claude-Providers und das Aufheben der external_control_plane_task-Blockade.
