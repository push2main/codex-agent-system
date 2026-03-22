# Dashboard Design Inventory

Kurzgrundlage fuer die Designableitung aus dem heutigen stabilen Bestand von `codex-dashboard/index.html` und `codex-dashboard/server.js`.

## Stabil darstellbare UI-Bereiche

- Hero / Topbar: Produktname, kurzer Zwecktext, `state-pill`, `address-pill`, `port-pill`.
- Intake-Bereich: Formular `Add Task` mit Projektwahl/-eingabe, Task, Context/Why, Success Criteria, Constraints, Affected Files.
- Prompt-Intake: separates Formular zur Ableitung kleiner Approval-Tasks aus einem groesseren Prompt.
- System-Status-Karte: Laufzeitstatus, Projekt, aktiver Task, Note, `updated_at`, Codex-Auth-Panel, Strategy-Loop-Panel, Retry-Button.
- Task-Board: `task-next-action`, kompakte Summary-Metriken, Filterleiste, optionaler Live-Work-Strip, drei Spalten fuer `Pending Approval`, `Ready To Execute`, `Implemented / Other`.
- Logs: dedizierte Log-Flaeche mit `/api/logs`.
- Sidebar-Metriken: persistente Kennzahlenkarte mit `/api/metrics`.
- Queue-Watch: separate Liste bereits gequeue-ter Arbeit.

## Bereits vorhandene Statuskarten und Listen

- Metrikkarten: `Total runs`, `Success rate`, `Tracked tasks`, `Queued`, `Pending approval`, `Approved`, `Codex auth`, `Avg duration`.
- Task-Summary-Karten: `Tracked`, `Pending`, `Approved`, `Implemented`, `Failed/Rejected`.
- Task-Listen:
  - `pending-tasks`: Pending-Approval-Karten mit Edit-vor-Approval sowie `Approve + Queue` / `Reject`.
  - `approved-tasks`: freigegebene Arbeit, die auf Ausfuehrung wartet.
  - `other-tasks`: implementierte, fehlgeschlagene oder abgelehnte Tasks, standardmaessig kompakter ueber `details`.
  - `queue`: Projekt + Task fuer die aktuelle Queue-Sicht.
- Health-/Detail-Panels:
  - Codex Auth: healthy / recovered / blocked.
  - Strategy Loop: running / stale / failed.
  - Live Work: aktiver Titel, Provider, aktueller Schritt.
  - Execution/History in Task-Karten: letzte Ausfuehrung und letzte Aktivitaeten.

## Heute verfuegbare, stabil nutzbare Datenfelder

- Globaler Runtime-Status aus `/api/status`:
  - `state`, `last_result`, `project`, `task`, `note`, `updated_at`, `port`, `addresses`, `protocol`
  - `authHealth`
  - `strategy`
  - `capabilities`, `reload_drift_summary` bzw. `runtime.reload_drift.summary`
- Metriken aus `/api/metrics`:
  - `total`, `success`, `failure`, `successRate`, `queued`, `pendingApproval`, `approved`
  - `taskRegistryTotal`, `averageDurationSeconds`, `averageScore`, `currentState`
  - `lastRun`, `lastFailed`, `settings`, `topPendingTask`, `nextAction`
  - `live_work_panel.items[]` mit `title`, `provider`, `worker`, `owner`, `current_work_label`
- Task-Registry aus `/api/task-registry`:
  - Top-Level pro Task: `id`, `title`, `project`, `category`, `status`, `rank`, `score`, `impact`, `effort`, `confidence`, `reason`, `created_at`, `updated_at`
  - Zeitfelder je nach Zustand: `approved_at`, `completed_at`, `failed_at`, `rejected_at`, `split_at`
  - Ausfuehrung: `execution.state`, `execution.result`, `execution.attempt`, `execution.max_retries`, `execution.updated_at`, `execution.will_retry`, `execution.current_step`, `execution.current_step_index`, `execution.provider`, `execution.lane`, `execution.lease_state`, `execution.lease_claimed_at`, `execution.lease_released_at`
  - Execution-Kontext: `execution_context` inkl. plan-/fortschrittsnaher Felder wie `step_count`, `completed_steps`, `plan_steps`, `current_step`, `worker`, `owner`
  - Handoff/Provider: `queue_handoff.at`, `queue_handoff.project`, `queue_handoff.task`, `queue_handoff.status`, `queue_handoff.provider`, `execution_provider`, `provider_selection.selected`, `provider_selection.source`, `provider_selection.reason`
  - Audit/Intent: `history[]`, `history_preview[]`, `last_history_entry`, `task_intent`, `execution_context`, `failure_context`
- Summary aus `/api/task-registry.summary`:
  - `total`, `byStatus`, `byCategory`, `oldestPendingTask`, `topCategory`, `topTask`, `topPendingTask`, `topApprovedTask`, `nextAction`
  - audit-/governance-nahe Felder unter `security`, `audit`, `governance`

## Designableitungs-Grenze

- Stabil ist bereits eine informationsdichte Operations-Konsole mit klarer Trennung zwischen Intake, Runtime-Status, Task-Board, Queue, Logs und Sidebar-Metriken.
- Fuer die naechsten Designschritte sollten nur Reihenfolge, Betonung, Toolbar-/Card-Hierarchie und responsive Anordnung verfeinert werden.
- Nicht noetig ist ein Redesign der Datenstruktur: die bestehende API liefert schon genug fuer Summary, Statuskarten, Provider-/Live-Work-Hinweise, Audit-History und Task-Details.

## Uebertragbare UI-Muster aus dem ProofHub-Referenzartikel

- Informationshierarchie ueber persoenlichen Fokus vor Detailtiefe: Erst eine knappe "Was braucht jetzt Aufmerksamkeit?"-Ebene, dann Summary und darunter die eigentlichen Task-Spalten; das passt zur bestehenden `codex-dashboard`-Oberflaeche, weil mit `nextAction`, Live-Work-Daten und Summary-Metriken bereits genau diese priorisierte Signalkette vorhanden ist.
- Kartenstruktur mit kompakter Uebersicht plus aufklappbaren Details: Jede Arbeitskarte zeigt zunaechst Status, Verantwortlichkeit und Fortschritt knapp und laesst Audit-/Execution-Details erst nachgelagert sichtbar werden; das passt zur bestehenden Oberflaeche, weil Pending-, Approved- und Other-Tasks schon als Karten mit History- und Execution-Daten vorliegen und daher nur in ihrer Verdichtung, nicht inhaltlich, gestrafft werden muessen.
- Klare Ansichts- und Filterleiste direkt ueber dem Board: Eine kleine Toolbar mit Status-/Projektfilter und erklaerender Kontextzeile rahmt die Board-Spalten als steuerbare Arbeitsansicht; das passt zur bestehenden Oberflaeche, weil `task-board-toolbar`, `task-filter-row` und die Queue-/Projekt-Daten bereits vorhanden sind und ohne neue Backend-Daten staerker als Navigationsschicht genutzt werden koennen.

## Minimales Ziel-Design fuer `codex-dashboard/index.html`

Das Ziel-Design nutzt nur bereits vorhandene Daten aus `status`, `metrics`, `task-registry` und `queue`. Es veraendert nur Reihenfolge, Betonung und Abstaende innerhalb der bestehenden Kartenstruktur.

### Exakte Bereiche und Reihenfolge auf der Seite

1. Hero / Topbar unveraendert oben: `Codex Control`, Kurztext, `state-pill`, `address-pill`, `port-pill`.
2. Hauptspalte beginnt weiter mit `System Status` vor dem Intake: Die Runtime-Karte bleibt inhaltlich unveraendert, wird aber als erste Arbeitsorientierung direkt unter dem Hero gezeigt.
3. Direkt darunter `Task Board` als primaere Arbeitsflaeche:
   - zuerst `task-next-action`
   - dann `task-summary-note`
   - dann `task-summary`
   - dann `task-board-toolbar`
   - dann der optionale `live-work-strip`
   - dann die drei bestehenden Spalten `Pending Approval`, `Ready To Execute`, `Implemented / Other`
4. Danach erst die Eingabeebene als bestehender `Intake`-Block mit beiden Formularen `Add Task` und `Prompt Intake`.
5. Danach `Logs` unveraendert als eigene Observability-Flaeche.
6. Rechte Seitenleiste bleibt zweite Rail:
   - zuerst `Metrics`
   - danach `Queued Work`

### Benoetigte CSS-Anpassungen

- `console-main` soll die Reihenfolge `card-status`, `card-board`, `card-compose`, `card-logs` explizit steuern, ohne neue Container einzufuehren.
- `card-status` und `card-board` sollen leicht staerker gruppiert wirken als primaere Operations-Flaechen:
  - etwas geringerer Innenabstand unter ihren `card-head`-Texten
  - konsistente vertikale Abstaende zwischen `task-next-action`, `task-summary`, Toolbar und Board
- `task-board-shell` bleibt einspaltig, bekommt aber eine klarere vertikale Staffelung, damit `live-work-strip` als Zwischenebene zwischen Toolbar und Board lesbar ist.
- `task-summary` bleibt daten- und komponentenseitig unveraendert; nur das Grid darf auf Tablet frueher auf zwei Spalten stabilisiert werden, statt visuell in eine neue Kachelart ueberzugehen.
- `task-board-toolbar` soll auf groesseren Breiten die Filterzeile und den Hinweistext weiterhin in einer Zeile halten; auf kleinen Breiten bleibt sie gestapelt.
- `live-work-strip` bleibt auf iPad sichtbar, soll aber dieselbe Kartenoptik wie die bestehenden `detail-panel`-Bloecke behalten; keine neue Signalfarbe, keine neue Badge-Art.
- Keine Aenderung an Task-Karten-Typografie, Tag-System, Detail-Panels, `details`-Verhalten oder Button-Stilen, damit die Board-Karten auditierbar gleich bleiben.

### Bestehende Elemente, die unveraendert bleiben muessen

- Die drei Task-Spalten mit ihren IDs und Datenzielen: `pending-tasks`, `approved-tasks`, `other-tasks`.
- Die bestehende Filterlogik `actionable/pending/approved/other/all` inklusive `task-filter-note`.
- Die Datenbindung und Darstellung von `task-summary`, `task-next-action`, `live-work-strip`, `metrics`, `queue`, `logs`.
- Die Pending-Approval-Karten mit `Edit before approval`, `Approve + Queue` und `Reject`.
- Die bestehenden Audit- und Ausfuehrungsdetails in Task-Karten: Outcome-Tags, Handoff-Tag, `Recent execution`, `Recent activity`, `details` fuer historische Karten.
- Die Sidebar-Struktur mit `Metrics` und `Queued Work` als separate Rail.
- Die Hero-Pills und die Runtime-Health-Panels fuer `Codex Auth` und `Strategy Loop`.

### Nicht-Ziele

- Keine neuen API-Felder, keine neue Sidebar-Sektion, keine vierte Task-Spalte.
- Kein Wechsel zu Tabs, Drawer-Navigation, neuer Farbpalette oder neuer Kartenkomponente.
- Keine Zusammenlegung von Logs, Queue und Task-Board in eine einzige Multifunktionsflaeche.
