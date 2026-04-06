# Fortschrittsbericht — 2026-03-27 (Scheduled Run v6)

## Gesamtzustand: STALLED — Kritischer Infrastruktur-Bug blockiert alles

### Kernproblem: Queue-Mismatch zum 5. Mal

Die `queues/codex-agent-system.txt` ist **erneut 0 Bytes**. Die 3 Einträge existieren nur in `codex-queue/codex-agent-system.txt` (wird von Workern nicht gelesen). Das ist das **fünfte Mal** (v23, v24, v29, v30, jetzt), dass dieses Problem auftritt.

**Diagnose:** Die in v30 dokumentierte "Structural Fix" (queue-sync guard in `_strategy_loop_body()`) greift offensichtlich nicht, weil der Strategy-Loop selbst nicht läuft oder der Guard nicht korrekt implementiert wurde. Das manuelle Kopieren der Einträge wird bei jedem Neustart/Session-Wechsel wieder überschrieben oder die Datei wird geleert.

**Empfehlung:** Die Queue-Architektur mit zwei Verzeichnissen ist die Wurzel des Problems. Solange es zwei Verzeichnisse gibt, wird diese Desynchronisation immer wieder passieren. Die einzig nachhaltige Lösung ist:
1. **Sofort:** `codex-queue/` als einziges Verzeichnis verwenden ODER
2. **Sofort:** Worker so umkonfigurieren, dass sie aus `codex-queue/` lesen ODER
3. **Sofort:** Symlink `queues/codex-agent-system.txt` → `codex-queue/codex-agent-system.txt`

Option 3 ist die einfachste und risikoärmste Lösung (ein Befehl, sofort wirksam, kein Code-Refactor nötig).

---

### Success Rate

| Metrik | Wert | Trend |
|--------|------|-------|
| All-time | 15% | Baseline |
| Letzte 50 | 28% | +13pp vs. All-time |
| Letzte 20 | 10% | Regression (Timeout-Burst) |
| Non-Timeout | 27% | +6.2pp/100 Tasks (positiv) |

**Bewertung:** Die bereinigte Success-Rate (ohne Timeouts) zeigt echtes Lernen. Aber die letzten 20 Tasks sind eine starke Regression, verursacht durch zu komplexe superheld-Tasks (iOS, Android, Gamification) die immer in Timeouts enden. Das System generiert Tasks, die es nicht lösen kann.

---

### Task-Registry (20 Tasks)

| Status | Anzahl | Details |
|--------|--------|---------|
| Completed | 1 | task-004 (Planning-Budget Cap) |
| Failed | 3 | task-002, task-009, task-010 |
| Pending Approval | 1 | task-133 (Retry Success Rate) |
| Queued | 3 | task-130, 131, 132 — **blockiert seit 72h+** |
| Shelved | 12 | Zombie/Duplikate/Low-Priority |

**Nur 1 von 20 Tasks erfolgreich abgeschlossen.** Die 3 queued Tasks warten seit dem 24. März — komplett blockiert durch den Queue-Bug.

---

### Sind die aktuellen Tasks umsetzbar?

**task-130 (Improve first-pass success rate):** JA, umsetzbar. Zielt auf `agents/planner.sh`, einzelne Datei, klar definiert. Provider: claude. Sollte funktionieren, wenn der Queue-Bug gelöst wird.

**task-131 (Break retry churn):** JA, umsetzbar. Zielt auf `agents/orchestrator.sh`, einzelne Datei. Exponential Backoff ist ein bekanntes Pattern. Provider: claude.

**task-132 (Reduce strategy saturation):** JA, umsetzbar. Zielt auf `scripts/strategy-loop.sh`, einzelne Datei. Cooldown + Pruning sind klare Änderungen. Provider: claude.

**task-133 (Improve retry success rate):** PENDING APPROVAL. Provider: claude. Sollte approved werden — thematisch komplementär zu task-131.

**Fazit:** Die Tasks selbst sind gut definiert und folgen den Learned Rules (single file, spezifisch, claude-routed). Das Problem ist nicht die Task-Qualität, sondern die Infrastruktur.

---

### Notwendige Modifikationen

#### Kritisch (sofort)

1. **Queue-Symlink erstellen:** `ln -sf ../codex-queue/codex-agent-system.txt queues/codex-agent-system.txt` — behebt den Bug permanent statt ihn immer wieder manuell zu fixen.

2. **task-133 approven:** Wartet seit 2026-03-26, ist valide und komplementär zum bestehenden Queue.

#### Empfohlen (mittelfristig)

3. **Superheld-Tasks stoppen oder auf `missing_environment` setzen:** Die letzten 10 Failures kamen alle aus dem superheld-Projekt (iOS/Android/Gradle). Ohne lokales SDK sind diese Tasks nicht lösbar — sie drücken die Success-Rate und verschwenden Compute.

4. **Pipeline-Stale-Alert reparieren:** `pipeline_stale` Flag wurde manuell in v30 gecleart, aber die Bedingung ist wieder eingetreten (>48h keine Ausführung). Der Alert sollte automatisch feuern.

5. **Metrics: `first_pass_success_rate: 1.0` ist irreführend** — basiert auf nur 1 completed Task. Sollte erst ab n≥5 berechnet werden.

#### Nice-to-have

6. **Report-Bereinigung:** 40+ Fortschrittsberichte im Root-Verzeichnis. Diese sollten in `reports/` verschoben werden.

---

### Zusammenfassung

Das System hat echtes Lernpotenzial (Non-Timeout Success-Rate steigt), aber **ein einziger Infrastruktur-Bug (Queue-Mismatch) blockiert seit 72+ Stunden jeglichen Fortschritt**. Die Tasks sind gut, die Rules sind konsolidiert, die Provider-Routing funktioniert — aber nichts davon hilft, wenn die Worker-Queue leer ist.

**Priorität 1:** Symlink für Queue-Datei erstellen (1 Befehl, sofortige Wirkung).
**Priorität 2:** task-133 approven.
**Priorität 3:** superheld-Tasks als `missing_environment` klassifizieren.
