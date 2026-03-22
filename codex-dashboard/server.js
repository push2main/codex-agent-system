const http = require("http");
const https = require("https");
const fs = require("fs");
const fsp = fs.promises;
const os = require("os");
const path = require("path");
const crypto = require("crypto");

const ROOT = path.resolve(__dirname, "..");
const PORT = Number(process.env.DASHBOARD_PORT || 3000);
const HTTPS_ENABLED = String(process.env.DASHBOARD_HTTPS || "0") === "1";
const PROTOCOL = HTTPS_ENABLED ? "https" : "http";
const TLS_KEY_FILE =
  process.env.DASHBOARD_TLS_KEY_FILE || path.join(ROOT, "codex-logs", "dashboard-tls", "dashboard-key.pem");
const TLS_CERT_FILE =
  process.env.DASHBOARD_TLS_CERT_FILE || path.join(ROOT, "codex-logs", "dashboard-tls", "dashboard-cert.pem");
const QUEUE_LIMIT = Number(process.env.QUEUE_LIMIT || 20);
function envPath(name, fallback) {
  return process.env[name] || fallback;
}

const PATHS = {
  dashboard: __dirname,
  projects: envPath("DASHBOARD_PROJECTS_DIR", path.join(ROOT, "projects")),
  queues: envPath("DASHBOARD_QUEUES_DIR", path.join(ROOT, "queues")),
  agentctlRuntime: envPath("DASHBOARD_AGENTCTL_RUNTIME_FILE", path.join(ROOT, "codex-logs", "agentctl-runtime.env")),
  authFailure: envPath("DASHBOARD_AUTH_FAILURE_FILE", path.join(ROOT, "codex-logs", "codex-auth-failure.json")),
  logs: envPath("DASHBOARD_SYSTEM_LOG_FILE", path.join(ROOT, "codex-logs", "system.log")),
  strategyLatest: envPath("DASHBOARD_STRATEGY_LATEST_FILE", path.join(ROOT, "codex-logs", "strategy-latest.json")),
  metrics: envPath("DASHBOARD_METRICS_FILE", path.join(ROOT, "codex-learning", "metrics.json")),
  priority: envPath("DASHBOARD_PRIORITY_FILE", path.join(ROOT, "codex-memory", "priority.json")),
  rules: envPath("DASHBOARD_RULES_FILE", path.join(ROOT, "codex-learning", "rules.md")),
  taskLog: envPath("DASHBOARD_TASK_LOG_FILE", path.join(ROOT, "codex-memory", "tasks.log")),
  taskRegistry: envPath("DASHBOARD_TASK_REGISTRY_FILE", path.join(ROOT, "codex-memory", "tasks.json")),
  dashboardSettings: envPath("DASHBOARD_SETTINGS_FILE", path.join(ROOT, "codex-memory", "dashboard-settings.json")),
  status: envPath("DASHBOARD_STATUS_FILE", path.join(ROOT, "status.txt")),
};
const DEFAULT_PRIORITY_CATEGORIES = {
  stability: { weight: 1.8, success_rate: 0.76 },
  ui: { weight: 1.35, success_rate: 0.81 },
  performance: { weight: 1.1, success_rate: 0.7 },
  code_quality: { weight: 1.05, success_rate: 0.79 },
};
const PRIORITY_LEARNING_LOOKBACK = 6;
const MAX_PRIORITY_LEARNED_ADJUSTMENT = 0.25;
const TRACKED_RUNTIME_HELPER_SCRIPTS = [
  "scripts/lib.sh",
  "scripts/multi-queue.sh",
  "scripts/queue-worker.sh",
  "scripts/strategy-loop.sh",
  "agents/strategy.sh",
];
const PROJECT_MEMORY_FILES = {
  context: path.join(ROOT, "codex-memory", "context.md"),
  decisions: path.join(ROOT, "codex-memory", "decisions.md"),
  learnings: path.join(ROOT, "codex-memory", "learnings.md"),
  knowledge: path.join(ROOT, "codex-memory", "knowledge.json"),
};

function ensureFile(filePath, fallback = "") {
  if (!fs.existsSync(filePath)) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, fallback, "utf8");
  }
}

function ensureStructure() {
  fs.mkdirSync(PATHS.projects, { recursive: true });
  fs.mkdirSync(PATHS.queues, { recursive: true });
  ensureFile(PATHS.logs, "");
  ensureFile(
    PATHS.metrics,
    '{\n  "total_tasks": 0,\n  "success_rate": 0,\n  "analysis_runs": 0,\n  "pending_approval_tasks": 0,\n  "approved_tasks": 0,\n  "task_registry_total": 0,\n  "last_task_score": 0,\n  "manual_recovery_records": 0\n}\n',
  );
  ensureFile(PATHS.priority, `${JSON.stringify({ categories: DEFAULT_PRIORITY_CATEGORIES }, null, 2)}\n`);
  ensureFile(PATHS.rules, "# Learned Rules\n\n");
  ensureFile(PATHS.taskLog, "");
  ensureFile(PATHS.taskRegistry, '{\n  "tasks": []\n}\n');
  ensureFile(PATHS.dashboardSettings, '{\n  "approval_mode": "manual",\n  "updated_at": ""\n}\n');
  ensureFile(
    PATHS.status,
    "state=idle\nproject=\ntask=\nlast_result=NONE\nnote=Dashboard initialized\nupdated_at=\n",
  );
}

function formatLogLine(agent, level, message) {
  return `[${new Date().toISOString()}] [${agent}] ${level}: ${message}\n`;
}

function isStructuredLogLine(line) {
  return /^\[\d{4}-\d{2}-\d{2}T.*Z\] \[[^\]]+\] (INFO|WARN|ERROR): /.test(String(line || ""));
}

function nowUtc() {
  return new Date().toISOString();
}

function safeNumber(value, fallback = 0) {
  const numeric = Number(value);
  return Number.isFinite(numeric) ? numeric : fallback;
}

function clampNumber(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function safeInteger(value, fallback = 0) {
  const numeric = Number(value);
  return Number.isFinite(numeric) ? Math.trunc(numeric) : fallback;
}

function dashboardUrls(addresses) {
  const hosts = addresses.length ? addresses : ["localhost"];
  return hosts.map((host) => `${PROTOCOL}://${host}:${PORT}`);
}

function normalizeTask(task) {
  return String(task || "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

function sanitizeProjectName(name) {
  return String(name || "")
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .trim();
}

function sanitizeTaskText(value) {
  return String(value || "")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeProviderName(value) {
  const normalized = String(value || "")
    .toLowerCase()
    .trim();
  return normalized === "codex" || normalized === "claude" ? normalized : "";
}

function normalizeApprovalMode(value) {
  const normalized = String(value || "")
    .toLowerCase()
    .trim();
  return normalized === "auto" ? "auto" : "manual";
}

function splitListInput(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => sanitizeTaskText(entry)).filter(Boolean);
  }
  return String(value || "")
    .split(/\r?\n|,/)
    .map((entry) => sanitizeTaskText(entry))
    .filter(Boolean);
}

function sentenceCase(value) {
  const text = sanitizeTaskText(value);
  if (!text) {
    return "";
  }
  return text.charAt(0).toUpperCase() + text.slice(1);
}

function excerptText(value, limit = 220) {
  const text = sanitizeTaskText(value);
  if (!text || text.length <= limit) {
    return text;
  }
  return `${text.slice(0, Math.max(0, limit - 1)).trimEnd()}…`;
}

function inferTaskCategory(text, availableCategories = []) {
  const normalized = sanitizeTaskText(text).toLowerCase();
  const known = new Set(Array.isArray(availableCategories) ? availableCategories : []);
  const categoryChecks = [
    {
      category: "stability",
      pattern: /\b(stable|stability|retry|recover|recovery|queue|runtime|worker|restart|lease|lock|failure|error|bug|auth|secure|security|audit|governance)\b/,
    },
    {
      category: "ui",
      pattern: /\b(ui|dashboard|board|layout|mobile|iphone|ipad|tablet|card|badge|panel|sidebar|toolbar|view)\b/,
    },
    {
      category: "performance",
      pattern: /\b(performance|latency|fast|faster|cache|load|optimi[sz]e|throughput|render time)\b/,
    },
    {
      category: "code_quality",
      pattern: /\b(clean|cleanup|refactor|shape|consistency|prompt|task|learning|routing|context|metadata|maintain)\b/,
    },
  ];

  for (const entry of categoryChecks) {
    if (known.has(entry.category) && entry.pattern.test(normalized)) {
      return entry.category;
    }
  }
  if (known.has("code_quality")) {
    return "code_quality";
  }
  return availableCategories[0] || "code_quality";
}

function normalizePromptClause(value) {
  return sanitizeTaskText(
    String(value || "")
      .replace(/^[\s>*\-–—•]+/, "")
      .replace(/^\d+[\.\)]\s+/, "")
      .replace(/^(please|pls|need to|we need to|i need to|ich brauche(?: tasks?)?,? die|ich möchte|wir müssen|wir wollen)\s+/i, "")
      .replace(/[.;:,]+$/, ""),
  );
}

function splitPromptIntoTaskTitles(prompt) {
  const normalizedPrompt = String(prompt || "").replace(/\r/g, "\n");
  const rawLines = normalizedPrompt
    .split(/\n+/)
    .map((line) => line.trim())
    .filter(Boolean);
  const candidateParts = [];

  for (const rawLine of rawLines) {
    const line = rawLine.replace(/^[\s>*\-–—•]+/, "").replace(/^\d+[\.\)]\s+/, "").trim();
    if (!line) {
      continue;
    }
    const semicolonParts = line.split(/\s*[;|]\s*/).filter(Boolean);
    for (const part of semicolonParts) {
      const sentenceParts = part.split(/(?<=[.!?])\s+(?=[A-Z0-9ÄÖÜ])/).filter(Boolean);
      if (sentenceParts.length > 1) {
        candidateParts.push(...sentenceParts);
      } else {
        candidateParts.push(part);
      }
    }
  }

  let normalizedParts = candidateParts.map(normalizePromptClause).filter((part) => part.length >= 18);

  if (normalizedParts.length <= 1) {
    const base = normalizePromptClause(normalizedPrompt);
    const connectiveParts = base
      .split(/\s+(?:and|und|sowie|plus)\s+/i)
      .map(normalizePromptClause)
      .filter((part) => part.length >= 18);
    if (connectiveParts.length > 1) {
      normalizedParts = connectiveParts;
    } else if (base) {
      normalizedParts = [base];
    }
  }

  if (normalizedParts.length <= 1 && normalizedParts[0] && normalizedParts[0].length >= 80) {
    const summary = excerptText(normalizedParts[0], 110);
    normalizedParts = [
      `Inspect the current implementation and isolate the smallest safe change surface for ${summary}`,
      `Implement the smallest safe improvement for ${summary}`,
      `Verify the result and capture approval-ready completion checks for ${summary}`,
    ];
  }

  const seen = new Set();
  const titles = [];
  for (const part of normalizedParts) {
    const title = sentenceCase(part);
    const key = normalizeTask(title);
    if (!title || seen.has(key)) {
      continue;
    }
    seen.add(key);
    titles.push(title);
    if (titles.length >= 5) {
      break;
    }
  }
  return titles;
}

function validatePromptDerivedTitle(title, prompt) {
  const normalizedTitle = sanitizeTaskText(title);
  const normalizedPrompt = String(prompt || "");
  const metaPrompt = /^(you are|role:|goal:|core principles|system behavior)\b/i.test(
    sanitizeTaskText(normalizedPrompt),
  );
  const metaTailWords = normalizedTitle
    .toLowerCase()
    .replace(/^(analyze|identify|generate|prioritize|review|inspect)\s+/i, "")
    .match(/[a-z0-9]+/g);
  const genericMetaTail =
    Array.isArray(metaTailWords) &&
    metaTailWords.length > 0 &&
    metaTailWords.every((word) =>
      [
        "and",
        "or",
        "the",
        "a",
        "an",
        "its",
        "itself",
        "system",
        "systems",
        "project",
        "projects",
        "connected",
        "weakness",
        "weaknesses",
        "opportunity",
        "opportunities",
        "improvement",
        "improvements",
        "task",
        "tasks",
        "priority",
        "priorities",
        "analysis",
        "work",
        "backlog",
      ].includes(word),
    );
  if (!normalizedTitle) {
    return { ok: false, reason: "Derived task text is empty." };
  }
  if (normalizedTitle.length > 180) {
    return { ok: false, reason: "Derived task is too long to be a safe actionable board item." };
  }
  if (/^(you are|role:|goal:|core principles|system behavior)\b/i.test(normalizedTitle)) {
    return { ok: false, reason: "Derived task still looks like prompt framing instead of an actionable task." };
  }
  if (/(---|#\s|(?:^|\s)\*\s|core principles|system behavior|operate under human supervision)/i.test(normalizedTitle)) {
    return { ok: false, reason: "Derived task still contains prompt-spec formatting or policy text." };
  }
  if (metaPrompt && /^(analyze|identify|generate|prioritize|review|inspect)\b/i.test(normalizedTitle) && genericMetaTail) {
    return {
      ok: false,
      reason: "Derived task is still a generic planning/meta step instead of project-specific executable work.",
    };
  }
  if (/\b\d+$/.test(normalizedTitle) && /\b1[\.\)]\s|\b2[\.\)]\s|\b3[\.\)]\s/.test(normalizedPrompt)) {
    return { ok: false, reason: "Derived task still contains numbered-list spillover from the source prompt." };
  }
  return { ok: true };
}

function normalizeTaskIntentInput(input, project, title, category) {
  return {
    source: sanitizeTaskText(input.taskIntentSource || input.task_intent_source || "dashboard_backlog") || "dashboard_backlog",
    objective: title,
    project,
    category,
    context_hint: sanitizeTaskText(input.contextHint || input.context_hint || ""),
    constraints: splitListInput(input.constraints),
    success_signals: splitListInput(input.successCriteria || input.success_criteria || input.successSignals || input.success_signals),
    affected_files: splitListInput(input.affectedFiles || input.affected_files),
  };
}

function normalizeTaskIntentRecord(task, title, project, category) {
  const queueHandoff = task.queue_handoff && typeof task.queue_handoff === "object" ? task.queue_handoff : null;
  const queueTaskIntent =
    queueHandoff && queueHandoff.task_intent && typeof queueHandoff.task_intent === "object"
      ? queueHandoff.task_intent
      : null;
  const taskTaskIntent = task.task_intent && typeof task.task_intent === "object" ? task.task_intent : null;
  const sourceTaskIntent =
    taskTaskIntent || queueTaskIntent || queueHandoff
      ? {
          ...(queueTaskIntent || {}),
          ...(taskTaskIntent || {}),
        }
      : null;
  if (!sourceTaskIntent && !queueHandoff) {
    return null;
  }
  const fallbackObjective = sanitizeTaskText(queueHandoff?.task || title);
  const fallbackProject = sanitizeProjectName(queueHandoff?.project || project) || "codex-agent-system";
  const fallbackCategory = sanitizeTaskText(category) || "code_quality";
  const normalizedObjective = sanitizeTaskText(sourceTaskIntent?.objective || fallbackObjective) || fallbackObjective;
  return {
    source: sanitizeTaskText(sourceTaskIntent?.source || "dashboard_backlog") || "dashboard_backlog",
    objective: normalizedObjective,
    project: sanitizeProjectName(sourceTaskIntent?.project || fallbackProject) || "codex-agent-system",
    category: sanitizeTaskText(sourceTaskIntent?.category || fallbackCategory) || fallbackCategory,
    context_hint: sanitizeTaskText(sourceTaskIntent?.context_hint || sourceTaskIntent?.contextHint || ""),
    constraints: splitListInput(sourceTaskIntent?.constraints),
    success_signals: splitListInput(sourceTaskIntent?.success_signals || sourceTaskIntent?.successSignals),
    affected_files: splitListInput(sourceTaskIntent?.affected_files || sourceTaskIntent?.affectedFiles),
  };
}

function selectTaskProvider(input, taskIntent) {
  const explicit = normalizeProviderName(input.executionProvider || input.execution_provider || input.provider);
  if (explicit) {
    return {
      selected: explicit,
      source: "input",
      reason: `Provider was selected explicitly from the task payload: ${explicit}.`,
    };
  }

  const corpus = [
    input.title,
    input.task,
    input.reason,
    taskIntent?.objective,
    taskIntent?.context_hint,
    taskIntent?.constraints?.join(" "),
  ]
    .map((value) => String(value || ""))
    .join(" ")
    .toLowerCase();

  if (/(^|\W)(claude|anthropic)(\W|$)/.test(corpus)) {
    return {
      selected: "claude",
      source: "keyword",
      reason: "Task text explicitly references Claude or Anthropic.",
    };
  }

  return {
    selected: "codex",
    source: "default",
    reason: "Default provider is Codex when no explicit Claude hint is present.",
  };
}

function taskSlug(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40);
}

function buildPendingTaskRecord(projectTasks, categories, input) {
  const project = sanitizeProjectName(input.project || input.newProject || "");
  const title = sanitizeTaskText(input.title || input.task || "");
  const historyNote =
    sanitizeTaskText(input.historyNote || "Task was added from the dashboard backlog form.") ||
    "Task was added from the dashboard backlog form.";
  if (!project) {
    return { ok: false, status: 400, error: "Project is required." };
  }
  if (!title) {
    return { ok: false, status: 400, error: "Task is required." };
  }

  const taskKey = normalizeTask(title);
  const duplicate = (Array.isArray(projectTasks) ? projectTasks : []).find((task) => {
    const status = String(task?.status || "").trim().toLowerCase();
    if (!["pending_approval", "approved", "running"].includes(status)) {
      return false;
    }
    return normalizeTaskProject(task) === project && normalizeTask(taskExecutionText(task)) === taskKey;
  });
  if (duplicate) {
    return { ok: false, status: 409, error: "Task is already tracked and actionable for this project." };
  }

  const categoryNames = Object.keys(categories || {});
  const requestedCategory = String(input.category || "").trim().toLowerCase();
  const category =
    categoryNames.includes(requestedCategory)
      ? requestedCategory
      : input.inferCategory === true
        ? inferTaskCategory([title, input.reason, input.contextHint, input.context_hint].join(" "), categoryNames)
        : "code_quality";
  const categoryConfig = categories[category] || DEFAULT_PRIORITY_CATEGORIES.code_quality;
  const impact = clampNumber(Math.round(safeNumber(input.impact, 5)), 1, 10);
  const effort = clampNumber(Math.round(safeNumber(input.effort, 3)), 1, 10);
  const confidence = Number(
    clampNumber(safeNumber(input.confidence, categoryConfig.success_rate), 0, 1).toFixed(2),
  );
  const transitionAt = input.transitionAt || nowUtc();
  const taskIntent = normalizeTaskIntentInput(input, project, title, category);
  const providerSelection = selectTaskProvider(input, taskIntent);
  const nextTask = {
    id: nextTaskRegistryId(projectTasks, title),
    title,
    impact,
    effort,
    confidence,
    category,
    project,
    reason: sanitizeTaskText(input.reason || "Added from the dashboard for approval before queue execution."),
    score: taskScore({
      impact,
      effort,
      confidence,
      categoryWeight: safeNumber(categoryConfig.weight, 1),
    }),
    execution_provider: providerSelection.selected,
    provider_selection: {
      ...providerSelection,
      updated_at: transitionAt,
    },
    status: "pending_approval",
    task_intent: taskIntent,
    created_at: transitionAt,
    updated_at: transitionAt,
  };

  if (input.prompt && input.promptMeta && typeof input.promptMeta === "object") {
    nextTask.prompt_intake = {
      source: "dashboard_prompt_intake",
      prompt_excerpt: excerptText(input.prompt, 240),
      index: safeInteger(input.promptMeta.index, 1),
      total: safeInteger(input.promptMeta.total, 1),
      updated_at: transitionAt,
    };
  }

  nextTask.history = appendTaskHistory(
    nextTask,
    buildTaskHistoryEntry(nextTask, "create", "", "pending_approval", {
      at: transitionAt,
      note: historyNote,
      project,
      queueTask: title,
    }),
  );

  return { ok: true, task: nextTask };
}

async function readPriorityCategories() {
  const payload = await readJsonFile(PATHS.priority, { categories: DEFAULT_PRIORITY_CATEGORIES });
  const rawCategories = payload && typeof payload === "object" ? payload.categories : null;
  const categories = rawCategories && typeof rawCategories === "object" ? rawCategories : DEFAULT_PRIORITY_CATEGORIES;
  const normalized = {};

  for (const [name, config] of Object.entries(categories)) {
    if (!config || typeof config !== "object") {
      continue;
    }
    normalized[String(name)] = {
      weight: safeNumber(config.weight, 1),
      success_rate: clampNumber(safeNumber(config.success_rate, 0.8), 0, 1),
    };
  }

  return Object.keys(normalized).length ? normalized : DEFAULT_PRIORITY_CATEGORIES;
}

function priorityLearningTimestamp(task) {
  return (
    String(task?.updated_at || "").trim() ||
    String(task?.completed_at || "").trim() ||
    String(task?.failed_at || "").trim() ||
    String(task?.success_at || "").trim() ||
    String(task?.approved_at || "").trim() ||
    String(task?.created_at || "").trim()
  );
}

function listRecentCategoryOutcomeTasks(tasks, category, lookback = PRIORITY_LEARNING_LOOKBACK) {
  return (Array.isArray(tasks) ? tasks : [])
    .filter((task) => task && typeof task === "object")
    .filter((task) => String(task.category || "").trim() === String(category || "").trim())
    .filter((task) => {
      const status = String(task.status || "").trim().toLowerCase();
      return status === "success" || status === "failed";
    })
    .sort((left, right) => priorityLearningTimestamp(right).localeCompare(priorityLearningTimestamp(left)))
    .slice(0, Math.max(1, safeInteger(lookback, PRIORITY_LEARNING_LOOKBACK)));
}

function computePriorityCategoryLearning(config, tasks, category, lookback = PRIORITY_LEARNING_LOOKBACK) {
  const recentTasks = listRecentCategoryOutcomeTasks(tasks, category, lookback);
  if (!recentTasks.length) {
    return null;
  }

  const observedSuccessRate = Number(
    (
      recentTasks.filter((task) => String(task.status || "").trim().toLowerCase() === "success").length /
      recentTasks.length
    ).toFixed(2),
  );
  const predictedConfidence = Number(
    (
      recentTasks.reduce((total, task) => total + clampNumber(safeNumber(task.confidence, config.success_rate), 0, 1), 0) /
      recentTasks.length
    ).toFixed(2),
  );
  const confidenceDrift = Number((observedSuccessRate - predictedConfidence).toFixed(2));
  const learnedAdjustment = Number(
    clampNumber(
      Number(((predictedConfidence - observedSuccessRate) * 0.6).toFixed(2)),
      -MAX_PRIORITY_LEARNED_ADJUSTMENT,
      MAX_PRIORITY_LEARNED_ADJUSTMENT,
    ).toFixed(2),
  );

  return {
    observed_success_rate: observedSuccessRate,
    predicted_confidence: predictedConfidence,
    confidence_drift: confidenceDrift,
    learned_adjustment: learnedAdjustment,
    updated_at: priorityLearningTimestamp(recentTasks[0]),
  };
}

function applyPriorityLearningSnapshot(priorityPayload, tasks, lookback = PRIORITY_LEARNING_LOOKBACK) {
  const sourceCategories =
    priorityPayload && typeof priorityPayload.categories === "object" && priorityPayload.categories
      ? priorityPayload.categories
      : DEFAULT_PRIORITY_CATEGORIES;
  const learnedCategories = {};

  for (const [name, rawConfig] of Object.entries(sourceCategories)) {
    if (!rawConfig || typeof rawConfig !== "object") {
      continue;
    }
    const config = {
      ...rawConfig,
      weight: safeNumber(rawConfig.weight, 1),
      success_rate: clampNumber(safeNumber(rawConfig.success_rate, 0.8), 0, 1),
    };
    const learning = computePriorityCategoryLearning(config, tasks, name, lookback);
    learnedCategories[name] = learning ? { ...config, ...learning } : config;
  }

  return {
    ...priorityPayload,
    categories: learnedCategories,
  };
}

function taskScore({ impact, effort, confidence, categoryWeight }) {
  return Number(((impact * confidence * categoryWeight) / Math.max(effort, 1)).toFixed(2));
}

async function readText(filePath) {
  try {
    return await fsp.readFile(filePath, "utf8");
  } catch {
    return "";
  }
}

async function readJsonFile(filePath, fallback) {
  try {
    const raw = await readText(filePath);
    if (!raw.trim()) {
      return fallback;
    }
    return JSON.parse(raw);
  } catch {
    return fallback;
  }
}

async function writeJsonFile(filePath, payload) {
  await fsp.mkdir(path.dirname(filePath), { recursive: true });
  await fsp.writeFile(filePath, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
}

async function readDashboardSettings() {
  const payload = await readJsonFile(PATHS.dashboardSettings, {});
  return {
    approval_mode: normalizeApprovalMode(
      payload.approval_mode || payload.approvalMode || (payload.auto_approve ? "auto" : "manual"),
    ),
    updated_at: typeof payload.updated_at === "string" ? payload.updated_at : "",
  };
}

async function writeDashboardSettings(input) {
  const settings = {
    approval_mode: normalizeApprovalMode(input.approval_mode || input.approvalMode || input.mode),
    updated_at: input.updated_at || nowUtc(),
  };
  await writeJsonFile(PATHS.dashboardSettings, settings);
  return settings;
}

async function readStatus() {
  const raw = await readText(PATHS.status);
  return raw
    .split(/\r?\n/)
    .filter(Boolean)
    .reduce((result, line) => {
      const index = line.indexOf("=");
      if (index === -1) {
        return result;
      }
      const key = line.slice(0, index);
      const value = line.slice(index + 1);
      result[key] = value;
      return result;
    }, {});
}

async function readEnvFile(filePath) {
  const raw = await readText(filePath);
  return raw
    .split(/\r?\n/)
    .filter(Boolean)
    .reduce((result, line) => {
      const index = line.indexOf("=");
      if (index === -1) {
        return result;
      }
      const key = line.slice(0, index).trim();
      if (!key) {
        return result;
      }
      result[key] = line.slice(index + 1).trim();
      return result;
    }, {});
}

function matchesActiveDashboardRuntime(runtimeEnv) {
  const runtimePort = safeInteger(runtimeEnv.dashboard_port, 0);
  const runtimeScheme = String(runtimeEnv.dashboard_scheme || "").trim().toLowerCase();
  return runtimePort === PORT && runtimeScheme === PROTOCOL;
}

async function resolveAgentctlRuntimeFile() {
  const configuredPath = process.env.DASHBOARD_AGENTCTL_RUNTIME_FILE;
  if (configuredPath) {
    return configuredPath;
  }

  const runtimeDir = path.dirname(PATHS.agentctlRuntime);
  let entries = [];
  try {
    entries = await fsp.readdir(runtimeDir);
  } catch {
    const fallbackEnv = await readEnvFile(PATHS.agentctlRuntime).catch(() => null);
    return fallbackEnv && matchesActiveDashboardRuntime(fallbackEnv) ? PATHS.agentctlRuntime : "";
  }

  const candidateNames = entries
    .filter((entry) => /^agentctl-runtime(?:-[A-Za-z0-9._-]+)?\.env$/.test(entry))
    .sort();

  let selectedPath = "";
  let selectedUpdatedAt = "";

  for (const entry of candidateNames) {
    const candidatePath = path.join(runtimeDir, entry);
    const runtimeEnv = await readEnvFile(candidatePath);
    if (!matchesActiveDashboardRuntime(runtimeEnv)) {
      continue;
    }

    const updatedAt = String(runtimeEnv.updated_at || "").trim();
    if (!selectedUpdatedAt || updatedAt > selectedUpdatedAt) {
      selectedPath = candidatePath;
      selectedUpdatedAt = updatedAt;
    }
  }

  return selectedPath;
}

async function computeHelperScriptsFingerprint() {
  const digest = crypto.createHash("sha256");
  for (const relativePath of TRACKED_RUNTIME_HELPER_SCRIPTS) {
    digest.update(relativePath, "utf8");
    digest.update("\0", "utf8");
    try {
      const fileBuffer = await fsp.readFile(path.join(ROOT, relativePath));
      digest.update(fileBuffer);
    } catch {
      digest.update("missing", "utf8");
    }
    digest.update("\0", "utf8");
  }
  return digest.digest("hex");
}

function shortFingerprint(value) {
  const normalized = String(value || "").trim().toLowerCase();
  return /^[a-f0-9]{12,}$/.test(normalized) ? normalized.slice(0, 12) : "";
}

async function readRuntimeDashboardStatus(statusInput = null) {
  const runtimeFile = await resolveAgentctlRuntimeFile();
  const [runtimeEnv, currentHelperFingerprint] = await Promise.all([
    runtimeFile ? readEnvFile(runtimeFile) : Promise.resolve({}),
    computeHelperScriptsFingerprint(),
  ]);
  const activeHelperFingerprint = String(runtimeEnv.queue_helper_fingerprint || "").trim().toLowerCase();
  const sessionName = sanitizeTaskText(runtimeEnv.session_name || "codex-agent-system") || "codex-agent-system";
  const runtimeVersionShort = shortFingerprint(activeHelperFingerprint) || "unknown";
  const runtimeVersionLabel = `${sessionName}@${runtimeVersionShort}`;
  const currentHelperFingerprintShort = shortFingerprint(currentHelperFingerprint) || "unknown";
  const driftDetected = Boolean(activeHelperFingerprint) && activeHelperFingerprint !== currentHelperFingerprint;
  const restartNeeded = String(statusInput?.restart_needed || "").trim().toLowerCase() === "true";
  const driftStatus = !activeHelperFingerprint
    ? "unknown"
    : driftDetected
      ? restartNeeded
        ? "restart_needed"
        : "drifted"
      : "in_sync";
  const promptIntakeAllowed = Boolean(activeHelperFingerprint) && !driftDetected && !restartNeeded;

  let reloadDriftSummary = "Runtime helper fingerprint not recorded yet. Reload once to capture the active helper version.";
  if (activeHelperFingerprint && !driftDetected) {
    reloadDriftSummary = `In sync: runtime ${runtimeVersionShort} matches current helpers ${currentHelperFingerprintShort}.`;
  } else if (activeHelperFingerprint) {
    reloadDriftSummary = `Reload drift detected: runtime ${runtimeVersionShort} vs current helpers ${currentHelperFingerprintShort}${restartNeeded ? " (restart needed)." : "."}`;
  }

  return {
    runtime_version_label: runtimeVersionLabel,
    reload_drift_summary: reloadDriftSummary,
    runtime: {
      version: {
        label: runtimeVersionLabel,
        session_name: sessionName,
        helper_fingerprint: activeHelperFingerprint || "",
        helper_fingerprint_short: runtimeVersionShort,
      },
      reload_drift: {
        detected: driftDetected,
        restart_needed: restartNeeded,
        status: driftStatus,
        runtime_helper_fingerprint: activeHelperFingerprint || "",
        runtime_helper_fingerprint_short: runtimeVersionShort,
        current_helper_fingerprint: currentHelperFingerprint || "",
        current_helper_fingerprint_short: currentHelperFingerprintShort,
        summary: reloadDriftSummary,
      },
    },
    capabilities: {
      prompt_intake: promptIntakeAllowed,
    },
  };
}

async function writeStatus(nextStatus) {
  const status = {
    state: nextStatus.state || "idle",
    project: nextStatus.project || "",
    task: nextStatus.task || "",
    last_result: nextStatus.last_result || "NONE",
    note: nextStatus.note || "",
    updated_at: nextStatus.updated_at || nowUtc(),
  };
  const content = [
    `state=${status.state}`,
    `project=${status.project}`,
    `task=${status.task}`,
    `last_result=${status.last_result}`,
    `note=${status.note}`,
    `updated_at=${status.updated_at}`,
    "",
  ].join("\n");
  await fsp.writeFile(PATHS.status, content, "utf8");
}

async function readCodexAuthHealth(statusInput = null) {
  const payload = await readJsonFile(PATHS.authFailure, {});
  const reason = typeof payload.reason === "string" ? payload.reason.trim() : "";
  const detectedAt = typeof payload.detected_at === "string" ? payload.detected_at.trim() : "";
  const rawCooldown = Number(process.env.CODEX_AUTH_FAILURE_COOLDOWN_SECONDS || 900);
  const cooldownSeconds = Number.isFinite(rawCooldown) && rawCooldown > 0 ? Math.floor(rawCooldown) : 0;
  const stat = await fsp.stat(PATHS.authFailure).catch(() => null);
  const ageSeconds = stat ? Math.max(0, Math.floor((Date.now() - stat.mtimeMs) / 1000)) : null;
  const active = Boolean(reason) && cooldownSeconds > 0 && ageSeconds !== null && ageSeconds < cooldownSeconds;
  const remainingSeconds =
    active && ageSeconds !== null ? Math.max(cooldownSeconds - ageSeconds, 0) : 0;
  const queueState = String(statusInput?.state || "").toLowerCase();
  const queueNote = String(statusInput?.note || "");
  const blockedByStatus = queueState === "blocked" && queueNote.startsWith("waiting_for_codex_auth");

  let message = "No cached Codex auth failure.";
  if (active) {
    message = "Queue execution is paused until Codex authentication recovers.";
  } else if (reason) {
    message = "Last cached Codex auth failure has expired.";
  }

  return {
    active,
    age_seconds: ageSeconds,
    blocks_queue: active || blockedByStatus,
    cooldown_expires_at:
      stat && cooldownSeconds > 0 ? new Date(stat.mtimeMs + cooldownSeconds * 1000).toISOString() : "",
    cooldown_seconds: cooldownSeconds,
    detected_at: detectedAt,
    message,
    reason,
    remaining_seconds: remainingSeconds,
    status: active ? "blocked" : reason ? "recovered" : "healthy",
  };
}

async function readStrategyHealth() {
  const [payload, stat] = await Promise.all([
    readJsonFile(PATHS.strategyLatest, {}),
    fsp.stat(PATHS.strategyLatest).catch(() => null),
  ]);
  const message = typeof payload.message === "string" ? payload.message.trim() : "";
  const boardTasks = Array.isArray(payload?.data?.board_tasks)
    ? payload.data.board_tasks.filter((task) => task && typeof task === "object")
    : [];
  const status = String(payload.status || "").trim().toLowerCase();
  const ageSeconds = stat ? Math.max(0, Math.floor((Date.now() - stat.mtimeMs) / 1000)) : null;
  const intervalSeconds = Math.max(15, safeInteger(process.env.STRATEGY_INTERVAL_SECONDS, 60));
  const staleThresholdSeconds = Math.max(intervalSeconds * 3, safeInteger(process.env.STRATEGY_STALE_SECONDS, 180));
  const active = Boolean(stat) && status === "success" && ageSeconds !== null && ageSeconds <= staleThresholdSeconds;
  let state = "unknown";
  let title = "Unknown";

  if (stat && status === "success" && active) {
    state = "running";
    title = "Active";
  } else if (stat && status === "success") {
    state = "stale";
    title = "Stale";
  } else if (stat && status) {
    state = "failed";
    title = "Failed";
  }

  return {
    active,
    status: state,
    title,
    message: message || (stat ? "Strategy health is available." : "No strategy run has been recorded yet."),
    last_board_updates: boardTasks.length,
    board_tasks: boardTasks,
    last_run_at: stat ? new Date(stat.mtimeMs).toISOString() : "",
    next_run_in_seconds: ageSeconds === null ? null : Math.max(intervalSeconds - ageSeconds, 0),
  };
}

async function listProjects() {
  const [projectEntries, queueEntries] = await Promise.all([
    fsp.readdir(PATHS.projects, { withFileTypes: true }).catch(() => []),
    fsp.readdir(PATHS.queues, { withFileTypes: true }).catch(() => []),
  ]);
  const projectNames = new Set(
    projectEntries.filter((entry) => entry.isDirectory()).map((entry) => entry.name),
  );
  for (const entry of queueEntries) {
    if (entry.isFile() && entry.name.endsWith(".txt")) {
      projectNames.add(entry.name.replace(/\.txt$/, ""));
    }
  }
  return [...projectNames].sort();
}

async function readQueueTasks() {
  const entries = await fsp.readdir(PATHS.queues, { withFileTypes: true }).catch(() => []);
  const tasks = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".txt")) {
      continue;
    }
    const filePath = path.join(PATHS.queues, entry.name);
    const raw = await readText(filePath);
    for (const line of raw.split(/\r?\n/)) {
      const task = line.trim();
      if (task) {
        tasks.push({ project: entry.name.replace(/\.txt$/, ""), task });
      }
    }
  }
  return tasks;
}

async function queueTaskCount() {
  const tasks = await readQueueTasks();
  return tasks.length;
}

async function taskExistsAnywhere(project, task) {
  const normalized = normalizeTask(task);
  const [status, queueTasks] = await Promise.all([readStatus(), readQueueTasks()]);
  if (status.project === project && normalizeTask(status.task || "") === normalized) {
    return true;
  }
  return queueTasks.some(
    (entry) => entry.project === project && normalizeTask(entry.task) === normalized,
  );
}

function parseJsonLines(raw) {
  return raw
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .flatMap((line) => {
      try {
        return [JSON.parse(line)];
      } catch {
        return [];
      }
    });
}

function escapeRegExp(value) {
  return String(value || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function normalizeRecordProject(record) {
  return sanitizeProjectName(record?.project || record?.target_project || "codex-agent-system") || "codex-agent-system";
}

function countProjectTextMentions(raw, project) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const normalized = String(raw || "").toLowerCase();
  if (!normalized) {
    return 0;
  }
  const matches = normalized.match(new RegExp(escapeRegExp(projectKey), "g"));
  return matches ? matches.length : 0;
}

function normalizePatternField(value, fallback = "unknown") {
  const normalized = String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 64);
  return normalized || fallback;
}

function createReusablePatternRecord(input) {
  const category = normalizePatternField(input?.category, "code_quality");
  const trigger = normalizePatternField(input?.trigger, "unknown");
  const action = normalizePatternField(input?.action, "record");
  const outcome = normalizePatternField(input?.outcome, "observed");
  const sourceFileType = normalizePatternField(input?.source_file_type, "json");
  const key = [category, trigger, action, outcome, sourceFileType].join(":");
  return {
    pattern_id: `pattern-${crypto.createHash("sha1").update(key).digest("hex").slice(0, 12)}`,
    category,
    trigger,
    action,
    outcome,
    source_file_type: sourceFileType,
  };
}

function collectReusablePatternRecords(project, registryTasks, taskLogRecords, memoryFiles) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const projectRegistryTasks = (Array.isArray(registryTasks) ? registryTasks : []).filter(
    (task) => normalizeTaskProject(task) === projectKey,
  );
  const projectRecords = (Array.isArray(taskLogRecords) ? taskLogRecords : []).filter(
    (record) => normalizeRecordProject(record) === projectKey,
  );
  const knowledgePayload =
    memoryFiles?.knowledge && typeof memoryFiles.knowledge === "object" ? memoryFiles.knowledge : { rules: [] };
  const knowledgeRules = Array.isArray(knowledgePayload.rules) ? knowledgePayload.rules : [];
  const knowledgeMatches = knowledgeRules.filter((rule) =>
    JSON.stringify(rule || {})
      .toLowerCase()
      .includes(projectKey),
  );
  const patterns = [];
  const pushPattern = (input) => {
    patterns.push(createReusablePatternRecord(input));
  };

  for (const task of projectRegistryTasks) {
    const status = normalizePatternField(task?.status, "tracked");
    const source =
      task?.task_intent && typeof task.task_intent === "object"
        ? normalizePatternField(task.task_intent.source, "task_registry")
        : "task_registry";
    const executionResult = normalizePatternField(task?.execution?.result, status);
    pushPattern({
      category: task?.category || "code_quality",
      trigger: source,
      action: `status_${status}`,
      outcome: executionResult,
      source_file_type: "json",
    });
  }

  for (const record of projectRecords) {
    pushPattern({
      category: "code_quality",
      trigger: "task_log",
      action: "execute_task",
      outcome: normalizePatternField(record?.result, "unknown"),
      source_file_type: "log",
    });
  }

  for (const rule of knowledgeMatches) {
    pushPattern({
      category: rule?.category || "code_quality",
      trigger: "knowledge_rule",
      action: "record_rule",
      outcome: "available",
      source_file_type: "json",
    });
  }

  for (const [fileType, raw] of [
    ["context_md", memoryFiles?.context],
    ["decisions_md", memoryFiles?.decisions],
    ["learnings_md", memoryFiles?.learnings],
  ]) {
    if (countProjectTextMentions(raw, projectKey) > 0) {
      pushPattern({
        category: "code_quality",
        trigger: "project_memory",
        action: "capture_pattern",
        outcome: "available",
        source_file_type: fileType,
      });
    }
  }

  return patterns
    .sort((left, right) => left.pattern_id.localeCompare(right.pattern_id))
    .filter((pattern, index, items) => index === items.findIndex((entry) => entry.pattern_id === pattern.pattern_id));
}

function compactQueueState(project, queueTasks, registryTasks, status) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const queuedTasks = (Array.isArray(queueTasks) ? queueTasks : [])
    .filter((entry) => sanitizeProjectName(entry?.project || "") === projectKey)
    .map((entry) => sanitizeTaskText(entry?.task || ""))
    .filter(Boolean);
  const activeRegistryTasks = (Array.isArray(registryTasks) ? registryTasks : []).filter((task) => {
    const executionState = String(task?.execution?.state || "").trim().toLowerCase();
    return normalizeTaskProject(task) === projectKey && (executionState === "running" || executionState === "retrying");
  });
  const currentStatusProject = sanitizeProjectName(status?.project || "") || "";
  const currentStatusTask = sanitizeTaskText(status?.task || "");
  const currentStatusState = sanitizeTaskText(status?.state || "").toLowerCase();
  const statusMatchesProject = currentStatusProject === projectKey;
  const activeTaskTitle =
    (statusMatchesProject && currentStatusTask) ||
    sanitizeTaskText(activeRegistryTasks[0]?.title || activeRegistryTasks[0]?.execution?.current_step || "") ||
    queuedTasks[0] ||
    "";
  const derivedState =
    (statusMatchesProject && currentStatusState) ||
    (activeRegistryTasks.length ? String(activeRegistryTasks[0]?.execution?.state || "").trim().toLowerCase() : "") ||
    (queuedTasks.length ? "queued" : "idle") ||
    "idle";
  return {
    queued_count: queuedTasks.length,
    active_count: activeRegistryTasks.length,
    state: derivedState || "idle",
    active_task: activeTaskTitle,
    note: statusMatchesProject ? sanitizeTaskText(status?.note || "") : "",
    queued_tasks_preview: queuedTasks.slice(0, 3),
  };
}

function buildProjectHealthMetrics(project, registryTasks, taskLogRecords) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const projectRegistryTasks = (Array.isArray(registryTasks) ? registryTasks : []).filter(
    (task) => normalizeTaskProject(task) === projectKey,
  );
  const projectRecords = (Array.isArray(taskLogRecords) ? taskLogRecords : []).filter(
    (record) => normalizeRecordProject(record) === projectKey,
  );
  const registryCounts = {
    pending_approval: 0,
    approved: 0,
    running: 0,
    retrying: 0,
    completed: 0,
    failed: 0,
    other: 0,
  };

  for (const task of projectRegistryTasks) {
    const status = String(task?.status || "").trim().toLowerCase();
    const executionState = String(task?.execution?.state || "").trim().toLowerCase();
    if (status === "pending_approval") {
      registryCounts.pending_approval += 1;
    } else if (status === "approved") {
      registryCounts.approved += 1;
    } else if (status === "completed" || status === "success") {
      registryCounts.completed += 1;
    } else if (status === "failed") {
      registryCounts.failed += 1;
    } else {
      registryCounts.other += 1;
    }

    if (executionState === "running") {
      registryCounts.running += 1;
    }
    if (executionState === "retrying") {
      registryCounts.retrying += 1;
    }
  }

  const successCount = projectRecords.filter((record) => String(record?.result || "").trim().toUpperCase() === "SUCCESS").length;
  const failureCount = projectRecords.filter((record) => String(record?.result || "").trim().toUpperCase() === "FAILURE").length;
  const lastRecord = projectRecords.at(-1) || null;

  return {
    task_log_total: projectRecords.length,
    task_log_success: successCount,
    task_log_failure: failureCount,
    task_log_success_rate:
      projectRecords.length > 0 ? Number(((successCount / projectRecords.length) * 100).toFixed(1)) : 0,
    registry_total: projectRegistryTasks.length,
    pending_approval: registryCounts.pending_approval,
    approved: registryCounts.approved,
    running: registryCounts.running,
    retrying: registryCounts.retrying,
    completed: registryCounts.completed,
    failed: registryCounts.failed,
    other: registryCounts.other,
    last_result: typeof lastRecord?.result === "string" ? lastRecord.result : "",
    last_result_at:
      typeof lastRecord?.completed_at === "string"
        ? lastRecord.completed_at
        : typeof lastRecord?.timestamp === "string"
          ? lastRecord.timestamp
          : "",
  };
}

function buildProjectMemorySummary(project, registryTasks, taskLogRecords, memoryFiles) {
  const projectKey = sanitizeProjectName(project) || "codex-agent-system";
  const projectRegistryTasks = (Array.isArray(registryTasks) ? registryTasks : []).filter(
    (task) => normalizeTaskProject(task) === projectKey,
  );
  const projectRecords = (Array.isArray(taskLogRecords) ? taskLogRecords : []).filter(
    (record) => normalizeRecordProject(record) === projectKey,
  );
  const contextRaw = typeof memoryFiles?.context === "string" ? memoryFiles.context : "";
  const decisionsRaw = typeof memoryFiles?.decisions === "string" ? memoryFiles.decisions : "";
  const learningsRaw = typeof memoryFiles?.learnings === "string" ? memoryFiles.learnings : "";
  const knowledgePayload =
    memoryFiles?.knowledge && typeof memoryFiles.knowledge === "object" ? memoryFiles.knowledge : { rules: [] };
  const knowledgeRules = Array.isArray(knowledgePayload.rules) ? knowledgePayload.rules : [];
  const knowledgeMatches = knowledgeRules.filter((rule) =>
    JSON.stringify(rule || {})
      .toLowerCase()
      .includes(projectKey),
  );

  return {
    registry_task_count: projectRegistryTasks.length,
    log_record_count: projectRecords.length,
    context_mentions: countProjectTextMentions(contextRaw, projectKey),
    decisions_mentions: countProjectTextMentions(decisionsRaw, projectKey),
    learnings_mentions: countProjectTextMentions(learningsRaw, projectKey),
    knowledge_rule_count: knowledgeMatches.length,
    reusable_patterns: collectReusablePatternRecords(projectKey, registryTasks, taskLogRecords, memoryFiles),
    memory_files_present: {
      context: Boolean(contextRaw.trim()),
      decisions: Boolean(decisionsRaw.trim()),
      learnings: Boolean(learningsRaw.trim()),
      knowledge: knowledgeRules.length > 0,
    },
  };
}

async function buildProjectSummaries() {
  const [projects, registryTasks, queueTasks, status, taskLog, context, decisions, learnings, knowledge] = await Promise.all([
    listProjects(),
    readTaskRegistry(),
    readQueueTasks(),
    readStatus(),
    readText(PATHS.taskLog),
    readText(PROJECT_MEMORY_FILES.context),
    readText(PROJECT_MEMORY_FILES.decisions),
    readText(PROJECT_MEMORY_FILES.learnings),
    readJsonFile(PROJECT_MEMORY_FILES.knowledge, { rules: [] }),
  ]);
  const taskLogRecords = parseJsonLines(taskLog);
  const knownProjects = new Set(Array.isArray(projects) ? projects : []);

  for (const task of Array.isArray(registryTasks) ? registryTasks : []) {
    knownProjects.add(normalizeTaskProject(task));
  }
  for (const entry of Array.isArray(queueTasks) ? queueTasks : []) {
    knownProjects.add(sanitizeProjectName(entry?.project || "") || "codex-agent-system");
  }
  if (sanitizeProjectName(status?.project || "")) {
    knownProjects.add(sanitizeProjectName(status.project));
  }
  if (!knownProjects.size) {
    knownProjects.add("codex-agent-system");
  }

  const memoryFiles = {
    context,
    decisions,
    learnings,
    knowledge,
  };

  return [...knownProjects]
    .filter(Boolean)
    .sort()
    .map((project) => ({
      project,
      health_metrics: buildProjectHealthMetrics(project, registryTasks, taskLogRecords),
      queue: compactQueueState(project, queueTasks, registryTasks, status),
      memory_summary: buildProjectMemorySummary(project, registryTasks, taskLogRecords, memoryFiles),
      status_summary: {
        current_status: sanitizeTaskText(
          (sanitizeProjectName(status?.project || "") || "") === project ? String(status?.state || "").toLowerCase() : "",
        ),
        current_task: sanitizeTaskText(
          (sanitizeProjectName(status?.project || "") || "") === project ? status?.task || "" : "",
        ),
        updated_at:
          (sanitizeProjectName(status?.project || "") || "") === project && typeof status?.updated_at === "string"
            ? status.updated_at
            : "",
      },
    }));
}

function readTlsCredentials() {
  try {
    return {
      key: fs.readFileSync(TLS_KEY_FILE, "utf8"),
      cert: fs.readFileSync(TLS_CERT_FILE, "utf8"),
    };
  } catch (error) {
    throw new Error(
      `HTTPS requested but TLS files could not be read: key=${TLS_KEY_FILE} cert=${TLS_CERT_FILE} (${error.message})`,
    );
  }
}

async function readTaskRegistry() {
  const payload = await readJsonFile(PATHS.taskRegistry, { tasks: [] });
  const tasks = Array.isArray(payload.tasks) ? payload.tasks : [];
  return tasks
    .filter((task) => task && typeof task === "object" && typeof task.title === "string")
    .map((task, index) => {
      const title = String(task.title || "").trim();
      const fallbackId = `task-${String(index + 1).padStart(3, "0")}-${taskSlug(title) || "untitled"}`;
      const createdAt =
        typeof task.created_at === "string" && task.created_at.trim() ? task.created_at.trim() : "";
      const updatedAt =
        typeof task.updated_at === "string" && task.updated_at.trim() ? task.updated_at.trim() : createdAt;
      const history = Array.isArray(task.history)
        ? task.history
            .filter((entry) => entry && typeof entry === "object")
            .map((entry) => ({
              ...entry,
              action: typeof entry.action === "string" ? entry.action : "",
              at: typeof entry.at === "string" ? entry.at : "",
              from_status: typeof entry.from_status === "string" ? entry.from_status : "",
              note: typeof entry.note === "string" ? entry.note : "",
              project: typeof entry.project === "string" ? entry.project : "",
              queue_task: typeof entry.queue_task === "string" ? entry.queue_task : "",
              to_status: typeof entry.to_status === "string" ? entry.to_status : "",
            }))
        : [];
      const rawExecution = task.execution && typeof task.execution === "object" ? task.execution : null;
      const rawProviderSelection =
        task.provider_selection && typeof task.provider_selection === "object" ? task.provider_selection : {};
      const executionProvider =
        normalizeProviderName(task.execution_provider || rawExecution?.provider || rawProviderSelection.selected) || "codex";
      const providerSelection = {
        selected: executionProvider,
        source: typeof rawProviderSelection.source === "string" && rawProviderSelection.source.trim()
          ? rawProviderSelection.source.trim()
          : executionProvider === "codex"
            ? "default"
            : "task_registry",
        reason:
          typeof rawProviderSelection.reason === "string" && rawProviderSelection.reason.trim()
            ? rawProviderSelection.reason.trim()
            : executionProvider === "codex"
              ? "Default provider is Codex when no explicit Claude hint is present."
              : `Provider is pinned on the task: ${executionProvider}.`,
      };
      const taskProject = sanitizeProjectName(task.project || "codex-agent-system") || "codex-agent-system";
      const taskCategory = typeof task.category === "string" ? task.category : "code_quality";
      const taskIntent = normalizeTaskIntentRecord(task, title, taskProject, taskCategory);
      const queueHandoff = task.queue_handoff && typeof task.queue_handoff === "object"
        ? {
            ...task.queue_handoff,
            at: typeof task.queue_handoff.at === "string" ? task.queue_handoff.at : "",
            project: sanitizeProjectName(task.queue_handoff.project || taskProject) || "codex-agent-system",
            task: sanitizeTaskText(task.queue_handoff.task || title),
            status: typeof task.queue_handoff.status === "string" ? task.queue_handoff.status : "",
            provider: normalizeProviderName(task.queue_handoff.provider || executionProvider) || executionProvider,
            ...(taskIntent ? { task_intent: taskIntent } : {}),
          }
        : null;
      const execution = rawExecution
        ? {
            ...rawExecution,
            attempt: safeInteger(rawExecution.attempt, 0),
            current_step: sanitizeTaskText(rawExecution.current_step || ""),
            current_step_index: safeInteger(rawExecution.current_step_index, 0),
            max_retries: safeInteger(rawExecution.max_retries, 0),
            result: typeof rawExecution.result === "string" ? rawExecution.result : "",
            state: typeof rawExecution.state === "string" ? rawExecution.state : "",
            updated_at: typeof rawExecution.updated_at === "string" ? rawExecution.updated_at : "",
            will_retry: Boolean(rawExecution.will_retry),
            provider: executionProvider,
            lane: typeof rawExecution.lane === "string" ? rawExecution.lane : "",
            lease_state: typeof rawExecution.lease_state === "string" ? rawExecution.lease_state : "",
            lease_claimed_at: typeof rawExecution.lease_claimed_at === "string" ? rawExecution.lease_claimed_at : "",
            lease_released_at: typeof rawExecution.lease_released_at === "string" ? rawExecution.lease_released_at : "",
          }
        : null;
      const historyPreview = history.slice(-2).reverse();

      return {
        ...task,
        id: typeof task.id === "string" && task.id.trim() ? task.id.trim() : fallbackId,
        title,
        category: typeof task.category === "string" ? task.category : "code_quality",
        confidence: Number(task.confidence || 0),
        created_at: createdAt,
        execution,
        execution_context: task.execution_context && typeof task.execution_context === "object" ? task.execution_context : null,
        execution_provider: executionProvider,
        effort: Number(task.effort || 0),
        failure_context: task.failure_context && typeof task.failure_context === "object" ? task.failure_context : null,
        history,
        history_preview: historyPreview,
        impact: Number(task.impact || 0),
        last_history_entry: history.length ? history[history.length - 1] : null,
        provider_selection: providerSelection,
        project: taskProject,
        queue_handoff: queueHandoff,
        score: Number(task.score || 0),
        status: typeof task.status === "string" ? task.status : "pending_approval",
        task_intent: taskIntent,
        updated_at: updatedAt,
      };
    })
    .sort((left, right) => Number(right.score || 0) - Number(left.score || 0))
    .map((task, index) => ({
      ...task,
      rank: index + 1,
    }));
}

function summarizeTaskRegistry(tasks, authHealth = null) {
  const byStatus = {
    pending_approval: 0,
    approved: 0,
    completed: 0,
    other: 0,
  };
  const byCategory = {};
  const providerCoverage = {
    codex: 0,
    claude: 0,
    unknown: 0,
  };
  let tasksWithHistory = 0;
  let totalHistoryEntries = 0;
  let queueHandoffs = 0;
  let rejectedTasks = 0;
  let splitTasks = 0;
  let tasksWithIntent = 0;
  let lastRecordedEventAt = "";

  for (const task of tasks) {
    const status = String(task.status || "").toLowerCase();
    if (status === "pending_approval" || status === "approved" || status === "completed") {
      byStatus[status] += 1;
    } else {
      byStatus.other += 1;
    }

    const category = String(task.category || "code_quality");
    byCategory[category] = (byCategory[category] || 0) + 1;

    const provider = normalizeProviderName(task.execution_provider || task.provider_selection?.selected);
    if (provider) {
      providerCoverage[provider] += 1;
    } else {
      providerCoverage.unknown += 1;
    }

    const history = Array.isArray(task.history) ? task.history : [];
    if (history.length) {
      tasksWithHistory += 1;
      totalHistoryEntries += history.length;
    }

    if (task.queue_handoff && typeof task.queue_handoff === "object") {
      queueHandoffs += 1;
      const handoffAt = typeof task.queue_handoff.at === "string" ? task.queue_handoff.at.trim() : "";
      if (handoffAt && (!lastRecordedEventAt || handoffAt > lastRecordedEventAt)) {
        lastRecordedEventAt = handoffAt;
      }
    }

    if (task.task_intent && typeof task.task_intent === "object") {
      tasksWithIntent += 1;
    }

    if (status === "rejected") {
      rejectedTasks += 1;
    }
    if (status === "split") {
      splitTasks += 1;
    }

    for (const candidate of [
      task.updated_at,
      task.created_at,
      task.approved_at,
      task.completed_at,
      task.failed_at,
      task.rejected_at,
      task.split_at,
      ...history.map((entry) => entry?.at),
    ]) {
      const timestamp = typeof candidate === "string" ? candidate.trim() : "";
      if (timestamp && (!lastRecordedEventAt || timestamp > lastRecordedEventAt)) {
        lastRecordedEventAt = timestamp;
      }
    }
  }

  const topTask = tasks[0] || null;
  const topPendingTask = tasks.find((task) => task.status === "pending_approval") || null;
  const topApprovedTask = tasks.find((task) => task.status === "approved") || null;
  const oldestPendingTask = tasks
    .filter((task) => task.status === "pending_approval" && task.created_at)
    .sort((left, right) => String(left.created_at).localeCompare(String(right.created_at)))[0] || null;
  const topCategoryEntry = Object.entries(byCategory).sort(
    (left, right) => right[1] - left[1] || left[0].localeCompare(right[0]),
  )[0] || null;

  let nextAction = {
    state: "idle",
    message: "No tracked tasks yet.",
  };
  const authBlocked = Boolean(authHealth?.blocks_queue);

  if (authHealth?.active && topApprovedTask) {
    nextAction = {
      state: "blocked",
      message: `Resolve Codex auth before executing: ${topApprovedTask.title}`,
    };
  } else if (authHealth?.active && topPendingTask) {
    nextAction = {
      state: "blocked",
      message: "Codex auth is blocked; avoid approving more work until it recovers.",
    };
  } else if (topApprovedTask) {
    nextAction = {
      state: "ready",
      message: `Execute approved task: ${topApprovedTask.title}`,
    };
  } else if (topPendingTask) {
    nextAction = {
      state: "approval",
      message: `Review pending task: ${topPendingTask.title}`,
    };
  } else if (topTask) {
    nextAction = {
      state: "tracking",
      message: `Review tracked task state: ${topTask.title}`,
    };
  }

  return {
    total: tasks.length,
    byStatus,
    byCategory,
    oldestPendingTask,
    topCategory: topCategoryEntry ? { name: topCategoryEntry[0], count: topCategoryEntry[1] } : null,
    topTask,
    topPendingTask,
    topApprovedTask,
    nextAction,
    security: {
      auth_status: authBlocked ? "blocked" : authHealth?.reason ? "recovered" : "healthy",
      auth_blocked: authBlocked,
      auth_reason: String(authHealth?.reason || authHealth?.message || ""),
      blocked_approved_tasks: authBlocked ? byStatus.approved : 0,
      provider_coverage: providerCoverage,
    },
    audit: {
      tasks_with_history: tasksWithHistory,
      tasks_without_history: Math.max(tasks.length - tasksWithHistory, 0),
      total_history_entries: totalHistoryEntries,
      queue_handoffs: queueHandoffs,
      last_recorded_event_at: lastRecordedEventAt,
    },
    governance: {
      pending_approval_tasks: byStatus.pending_approval,
      approved_tasks: byStatus.approved,
      rejected_tasks: rejectedTasks,
      split_tasks: splitTasks,
      tasks_with_intent: tasksWithIntent,
    },
  };
}

function activeTaskSortKey(task) {
  const state = String(task?.execution?.state || "").toLowerCase();
  const lane = sanitizeTaskText(task?.execution?.lane || "");
  const title = sanitizeTaskText(task?.title || "");
  const stateRank = state === "running" ? "0" : state === "retrying" ? "1" : "2";
  return `${stateRank}:${lane}:${title}`;
}

function activeTaskWorkLabel(task) {
  const execution = task?.execution && typeof task.execution === "object" ? task.execution : {};
  const executionContext =
    task?.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const currentStep = sanitizeTaskText(execution.current_step || executionContext.current_step || "");
  if (currentStep) {
    return currentStep;
  }

  const planSteps = Array.isArray(executionContext.plan_steps) ? executionContext.plan_steps : [];
  const completedSteps = Math.max(0, safeInteger(executionContext.completed_steps, 0));
  const nextPlannedStep = sanitizeTaskText(planSteps[completedSteps] || "");
  if (nextPlannedStep) {
    return nextPlannedStep;
  }

  if (String(execution.state || "").toLowerCase() === "retrying") {
    return "Retry queued";
  }
  return "In progress";
}

function activeTaskOwnership(task, provider) {
  const execution = task?.execution && typeof task.execution === "object" ? task.execution : {};
  const executionContext =
    task?.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const worker = sanitizeTaskText(execution.worker || executionContext.worker || execution.lane || "");
  const owner = sanitizeTaskText(task?.owner || execution.owner || executionContext.owner || worker || provider);
  return {
    worker,
    owner: owner || provider,
  };
}

function buildLiveWorkPanel(tasks) {
  const items = (Array.isArray(tasks) ? tasks : [])
    .filter((task) => {
      const state = String(task?.execution?.state || "").toLowerCase();
      return state === "running" || state === "retrying";
    })
    .slice()
    .sort((left, right) => activeTaskSortKey(left).localeCompare(activeTaskSortKey(right)))
    .map((task) => {
      const provider =
        normalizeProviderName(task?.execution?.provider || task?.execution_provider || task?.provider_selection?.selected) ||
        "codex";
      const ownership = activeTaskOwnership(task, provider);
      return {
        title: sanitizeTaskText(task?.title || ""),
        provider,
        worker: ownership.worker,
        owner: ownership.owner,
        current_work_label: activeTaskWorkLabel(task),
      };
    });

  return {
    items,
  };
}

async function readTaskRegistryPayload() {
  const payload = await readJsonFile(PATHS.taskRegistry, { tasks: [] });
  return {
    ...payload,
    tasks: Array.isArray(payload.tasks) ? payload.tasks : [],
  };
}

async function writeTaskRegistryPayload(payload) {
  const tasks = pruneApprovedTasksForPersistence(Array.isArray(payload.tasks) ? payload.tasks : []);
  await writeJsonFile(PATHS.taskRegistry, {
    ...payload,
    tasks,
  });
}

function firstNonEmptyString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return "";
}

function latestHistoryTransitionAt(task, toStatus) {
  const entries = Array.isArray(task?.history) ? task.history : [];
  let latest = "";
  for (const entry of entries) {
    if (!entry || typeof entry !== "object") {
      continue;
    }
    if (String(entry.to_status || "").trim().toLowerCase() !== toStatus) {
      continue;
    }
    const at = typeof entry.at === "string" ? entry.at.trim() : "";
    if (at && (!latest || at > latest)) {
      latest = at;
    }
  }
  return latest;
}

function completionEvidenceForApprovedTask(task) {
  const execution = task?.execution && typeof task.execution === "object" ? task.execution : {};
  const executionContext = task?.execution_context && typeof task.execution_context === "object" ? task.execution_context : {};
  const completedAt = firstNonEmptyString(
    task?.completed_at,
    latestHistoryTransitionAt(task, "completed"),
    String(execution.state || "").trim().toLowerCase() === "completed" ? execution.updated_at : "",
    String(execution.result || "").trim().toUpperCase() === "SUCCESS" ? execution.updated_at : "",
    String(executionContext.result || "").trim().toUpperCase() === "SUCCESS" ? task?.updated_at : "",
  );
  if (!completedAt) {
    return null;
  }
  return {
    at: completedAt,
    note: "Approved task was pruned because completion evidence already exists on the task record.",
  };
}

function invalidEvidenceForApprovedTask(task) {
  const queueTask = taskExecutionText(task);
  if (!queueTask) {
    return {
      at: firstNonEmptyString(task?.updated_at, task?.created_at),
      note: "Approved task was pruned because it has no non-empty queue task text.",
    };
  }

  const promptSource = String(task?.prompt_intake?.source || task?.task_intent?.source || "")
    .trim()
    .toLowerCase();
  const title = sanitizeTaskText(task?.title || "");
  if (promptSource === "dashboard_prompt_intake") {
    if (title.length > 240 && (/^you are\b/i.test(title) || /---|[#*]/.test(title))) {
      return {
        at: firstNonEmptyString(task?.updated_at, task?.created_at),
        note: "Approved task was pruned because the prompt-intake title is still a raw instruction blob instead of a discrete task.",
      };
    }
    if (/https?:\/\//i.test(title)) {
      return {
        at: firstNonEmptyString(task?.updated_at, task?.created_at),
        note: "Approved task was pruned because the prompt-intake title still contains a raw URL instead of normalized task text.",
      };
    }
  }

  return null;
}

function supersedingEvidenceForApprovedTask(task, allTasks) {
  const project = normalizeTaskProject(task);
  const taskKey = normalizeTask(taskExecutionText(task));
  if (!project || !taskKey) {
    return null;
  }

  const supersedingCandidate = (Array.isArray(allTasks) ? allTasks : [])
    .filter((candidate) => {
      if (!candidate || typeof candidate !== "object" || candidate === task) {
        return false;
      }
      if (normalizeTaskProject(candidate) !== project) {
        return false;
      }
      if (normalizeTask(taskExecutionText(candidate)) !== taskKey) {
        return false;
      }
      const status = String(candidate.status || "").trim().toLowerCase();
      return status === "running" || status === "completed";
    })
    .sort((left, right) => {
      const leftStatus = String(left.status || "").trim().toLowerCase();
      const rightStatus = String(right.status || "").trim().toLowerCase();
      const leftRank = leftStatus === "completed" ? 0 : 1;
      const rightRank = rightStatus === "completed" ? 0 : 1;
      if (leftRank !== rightRank) {
        return leftRank - rightRank;
      }
      const leftUpdated = firstNonEmptyString(left.updated_at, left.created_at);
      const rightUpdated = firstNonEmptyString(right.updated_at, right.created_at);
      return rightUpdated.localeCompare(leftUpdated);
    })[0];

  if (!supersedingCandidate) {
    return null;
  }

  return {
    at: firstNonEmptyString(supersedingCandidate.updated_at, supersedingCandidate.created_at, task.updated_at, task.created_at),
    note: `Approved task was pruned because duplicate work already advanced to ${String(
      supersedingCandidate.status || "",
    ).trim().toLowerCase()}.`,
  };
}

function pruneApprovedTask(task, allTasks) {
  const status = String(task?.status || "").trim().toLowerCase();
  if (status !== "approved") {
    return task;
  }

  const completionEvidence = completionEvidenceForApprovedTask(task);
  if (completionEvidence) {
    const transitionAt = firstNonEmptyString(completionEvidence.at, task.updated_at, task.created_at);
    const nextTask = {
      ...task,
      status: "completed",
      completed_at: firstNonEmptyString(task.completed_at, transitionAt),
      updated_at: transitionAt,
    };
    if (task.queue_handoff && typeof task.queue_handoff === "object") {
      nextTask.queue_handoff = {
        ...task.queue_handoff,
        status: "completed",
      };
    }
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "prune", "approved", "completed", {
        at: transitionAt,
        note: completionEvidence.note,
        project: normalizeTaskProject(task),
        queueTask: taskExecutionText(task),
      }),
    );
    return nextTask;
  }

  const supersedingEvidence = supersedingEvidenceForApprovedTask(task, allTasks);
  if (supersedingEvidence) {
    const transitionAt = firstNonEmptyString(supersedingEvidence.at, task.updated_at, task.created_at);
    const nextTask = {
      ...task,
      status: "rejected",
      rejected_at: firstNonEmptyString(task.rejected_at, transitionAt),
      updated_at: transitionAt,
    };
    if (task.queue_handoff && typeof task.queue_handoff === "object") {
      nextTask.queue_handoff = {
        ...task.queue_handoff,
        status: "pruned",
      };
    }
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "prune", "approved", "rejected", {
        at: transitionAt,
        note: supersedingEvidence.note,
        project: normalizeTaskProject(task),
        queueTask: taskExecutionText(task),
      }),
    );
    return nextTask;
  }

  const invalidEvidence = invalidEvidenceForApprovedTask(task);
  if (invalidEvidence) {
    const transitionAt = firstNonEmptyString(invalidEvidence.at, task.updated_at, task.created_at);
    const nextTask = {
      ...task,
      status: "rejected",
      rejected_at: firstNonEmptyString(task.rejected_at, transitionAt),
      updated_at: transitionAt,
    };
    if (task.queue_handoff && typeof task.queue_handoff === "object") {
      nextTask.queue_handoff = {
        ...task.queue_handoff,
        status: "pruned",
      };
    }
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "prune", "approved", "rejected", {
        at: transitionAt,
        note: invalidEvidence.note,
        project: normalizeTaskProject(task),
        queueTask: taskExecutionText(task),
      }),
    );
    return nextTask;
  }

  return task;
}

function pruneApprovedTasksForPersistence(tasks) {
  const input = Array.isArray(tasks) ? tasks : [];
  return input.map((task) => pruneApprovedTask(task, input));
}

function buildPersistedMetrics(tasks, records) {
  const registryTasks = Array.isArray(tasks) ? tasks.filter((task) => task && typeof task === "object") : [];
  const totalRecords = records.length;
  const successRecords = records.filter((record) => String(record.result || "").trim() === "SUCCESS").length;
  const pendingApproval = registryTasks.filter(
    (task) => String(task.status || "").trim().toLowerCase() === "pending_approval",
  ).length;
  const approved = registryTasks.filter(
    (task) => String(task.status || "").trim().toLowerCase() === "approved",
  ).length;
  const lastTask = registryTasks[registryTasks.length - 1] || null;
  const manualRecoveryRecords = records.filter(
    (record) => String(record.source || "").trim() === "manual_recovery",
  ).length;

  return {
    total_tasks: totalRecords,
    success_rate: totalRecords ? Number((successRecords / totalRecords).toFixed(2)) : 0,
    analysis_runs: registryTasks.length,
    pending_approval_tasks: pendingApproval,
    approved_tasks: approved,
    task_registry_total: registryTasks.length,
    last_task_score: lastTask ? safeNumber(lastTask.score, 0) : 0,
    manual_recovery_records: manualRecoveryRecords,
  };
}

async function refreshPersistedPriority(tasks = null) {
  const registryPayload = tasks === null ? await readTaskRegistryPayload() : { tasks };
  const priorityPayload = await readJsonFile(PATHS.priority, { categories: DEFAULT_PRIORITY_CATEGORIES });
  const learnedPriority = applyPriorityLearningSnapshot(priorityPayload, registryPayload.tasks);
  await writeJsonFile(PATHS.priority, learnedPriority);
  return learnedPriority;
}

async function refreshPersistedMetrics(tasks = null) {
  const [taskLog, registryPayload] = await Promise.all([
    readText(PATHS.taskLog),
    tasks === null ? readTaskRegistryPayload() : Promise.resolve({ tasks }),
  ]);
  const records = parseJsonLines(taskLog);
  const metrics = buildPersistedMetrics(registryPayload.tasks, records);
  await Promise.all([writeJsonFile(PATHS.metrics, metrics), refreshPersistedPriority(registryPayload.tasks)]);
  return metrics;
}

function buildTaskHistoryEntry(task, action, fromStatus, toStatus, extra = {}) {
  return {
    at: extra.at || nowUtc(),
    action,
    from_status: fromStatus,
    to_status: toStatus,
    project: extra.project || task.project || "",
    queue_task: extra.queueTask || task.execution_task || task.title || "",
    note: extra.note || "",
  };
}

function appendTaskHistory(task, entry) {
  const history = Array.isArray(task.history) ? task.history.slice(-19) : [];
  return [...history, entry];
}

function normalizeTaskProject(task) {
  return sanitizeProjectName(task.project || task.target_project || "codex-agent-system") || "codex-agent-system";
}

function taskExecutionText(task) {
  return sanitizeTaskText(task.execution_task || task.title || "");
}

function buildApprovalExecutionBrief({ approvedAt, project, queueTask, provider, queueStatus, taskIntent }) {
  const normalizedProject = sanitizeProjectName(project || "") || "codex-agent-system";
  const normalizedQueueTask = sanitizeTaskText(queueTask || "");
  const normalizedTaskIntent =
    taskIntent && typeof taskIntent === "object"
      ? normalizeTaskIntentRecord(
          {
            task_intent: taskIntent,
          },
          normalizedQueueTask,
          normalizedProject,
          sanitizeTaskText(taskIntent.category || "") || "code_quality",
        )
      : null;
  return {
    approved_at: typeof approvedAt === "string" ? approvedAt : "",
    project: normalizedProject,
    queue_task: normalizedQueueTask,
    provider: normalizeProviderName(provider) || "codex",
    status: typeof queueStatus === "string" ? queueStatus : "",
    task_intent: normalizedTaskIntent,
  };
}

function nextTaskRegistryId(tasks, title) {
  const maxIndex = (Array.isArray(tasks) ? tasks : []).reduce((highest, task) => {
    const match = /^task-(\d+)-/.exec(String(task?.id || "").trim());
    if (!match) {
      return highest;
    }
    return Math.max(highest, Number(match[1]) || 0);
  }, 0);
  const prefix = String(maxIndex + 1).padStart(3, "0");
  return `task-${prefix}-${taskSlug(title) || "untitled"}`;
}

async function createTaskRegistryItem(input) {
  const payload = await readTaskRegistryPayload();
  const successMessage =
    sanitizeTaskText(input.successMessage || "Task added to backlog.") || "Task added to backlog.";
  const successStatus = clampNumber(Math.round(safeNumber(input.successStatus, 201)), 200, 299);
  const projectTasks = Array.isArray(payload.tasks) ? payload.tasks : [];
  const categories = await readPriorityCategories();
  const result = buildPendingTaskRecord(projectTasks, categories, input);
  if (!result.ok) {
    return result;
  }
  const nextTask = result.task;

  payload.tasks = [...projectTasks, nextTask];
  await writeTaskRegistryPayload(payload);
  await refreshPersistedMetrics(payload.tasks);
  await appendLog(`Created pending task ${nextTask.id} for ${nextTask.project}: ${nextTask.title}`);

  if (input.autoApprove === true) {
    const autoApproval = await applyAutoApproveToTaskIds([nextTask.id]);
    const finalTask = autoApproval.tasksById[nextTask.id] || nextTask;
    return {
      ok: true,
      status: successStatus,
      task: finalTask,
      message: autoApproval.approved.length
        ? "Task auto-approved and queued."
        : `${successMessage} Auto-approve left the task pending: ${autoApproval.errors[0]?.error || "approval did not complete."}`,
      auto_approve: autoApproval,
    };
  }

  return {
    ok: true,
    status: successStatus,
    task: nextTask,
    message: successMessage,
  };
}

async function createTaskRegistryItemsFromPrompt(input) {
  const payload = await readTaskRegistryPayload();
  const projectTasks = Array.isArray(payload.tasks) ? payload.tasks : [];
  const categories = await readPriorityCategories();
  const project = sanitizeProjectName(input.project || input.newProject || "");
  const prompt = sanitizeTaskText(input.prompt || input.taskPrompt || input.task_prompt || "");
  if (!project) {
    return { ok: false, status: 400, error: "Project is required." };
  }
  if (!prompt) {
    return { ok: false, status: 400, error: "Prompt is required." };
  }

  const derivedTitles = splitPromptIntoTaskTitles(prompt);
  if (!derivedTitles.length) {
    return { ok: false, status: 400, error: "Prompt did not produce any actionable task candidates." };
  }

  const created = [];
  const skipped = [];
  const transitionAt = nowUtc();
  for (const [index, title] of derivedTitles.entries()) {
    const titleValidation = validatePromptDerivedTitle(title, prompt);
    if (!titleValidation.ok) {
      skipped.push({ title, reason: titleValidation.reason });
      continue;
    }
    const effort = title.length > 110 ? 4 : title.length > 70 ? 3 : 2;
    const category = inferTaskCategory(title, Object.keys(categories));
    const result = buildPendingTaskRecord(payload.tasks, categories, {
      project,
      title,
      task: title,
      category,
      impact: category === "ui" ? 7 : category === "stability" ? 8 : category === "performance" ? 7 : 6,
      effort,
      confidence: effort >= 4 ? 0.74 : 0.82,
      reason:
        sanitizeTaskText(
          input.reason ||
            `Derived from a dashboard prompt intake so the request can be reviewed as smaller approval-ready tasks.`,
        ) || `Derived from a dashboard prompt intake so the request can be reviewed as smaller approval-ready tasks.`,
      contextHint: `Derived from prompt: ${excerptText(prompt, 240)}`,
      successCriteria: `Task is reviewable on its own\nThe broader prompt is decomposed into smaller approval items`,
      constraints: `Keep the change small\nDo not bypass approval\nStay within the selected project`,
      historyNote: `Task was derived from dashboard prompt intake (${index + 1}/${derivedTitles.length}).`,
      taskIntentSource: "dashboard_prompt_intake",
      executionProvider: input.executionProvider || input.execution_provider,
      prompt,
      promptMeta: { index: index + 1, total: derivedTitles.length },
      transitionAt,
    });
    if (!result.ok) {
      if (result.status === 409) {
        skipped.push({ title, reason: result.error });
        continue;
      }
      return result;
    }
    payload.tasks = [...payload.tasks, result.task];
    created.push(result.task);
  }

  if (!created.length) {
    const duplicateOnly = skipped.length > 0 && skipped.every((entry) => entry.reason === "Task is already tracked and actionable for this project.");
    return {
      ok: false,
      status: duplicateOnly ? 409 : 400,
      error: duplicateOnly
        ? "Prompt only produced tasks that are already tracked for this project."
        : "Prompt only produced malformed or non-actionable task candidates.",
      skipped,
    };
  }

  await writeTaskRegistryPayload(payload);
  await refreshPersistedMetrics(payload.tasks);
  await appendLog(`Derived ${created.length} pending task(s) from prompt for ${project}.`);

  let responseTasks = created;
  let message = `Derived ${created.length} task${created.length === 1 ? "" : "s"} for ${project}.`;
  let autoApproval = null;
  if (input.autoApprove === true) {
    autoApproval = await applyAutoApproveToTaskIds(created.map((task) => task.id));
    responseTasks = created.map((task) => autoApproval.tasksById[task.id] || task);
    message = autoApproval.approved.length
      ? `Derived ${created.length} task${created.length === 1 ? "" : "s"} for ${project}; auto-approved ${autoApproval.approved.length}.`
      : `Derived ${created.length} task${created.length === 1 ? "" : "s"} for ${project}, but auto-approve left them pending.`;
  }

  return {
    ok: true,
    status: 201,
    tasks: responseTasks,
    created_count: created.length,
    skipped,
    message,
    ...(autoApproval ? { auto_approve: autoApproval } : {}),
  };
}

async function updateTaskRegistryItem(taskId, updates) {
  const payload = await readTaskRegistryPayload();
  const index = payload.tasks.findIndex((task) => String(task.id || "").trim() === taskId);
  if (index === -1) {
    return { ok: false, status: 404, error: "Task was not found." };
  }

  const existing = payload.tasks[index];
  const normalizedTask = (await readTaskRegistry()).find((task) => task.id === taskId);
  const fromStatus = String((normalizedTask || existing).status || "pending_approval");
  if (fromStatus !== "pending_approval") {
    return { ok: false, status: 409, error: "Only pending approval tasks can be edited." };
  }

  const currentTitle = sanitizeTaskText(existing.title || "");
  const currentProject = normalizeTaskProject(existing);
  const nextTitle = sanitizeTaskText(updates.title || currentTitle);
  const nextProject = sanitizeProjectName(updates.project || currentProject) || "codex-agent-system";
  if (!nextTitle) {
    return { ok: false, status: 400, error: "Pending tasks need a non-empty task text." };
  }

  const changedFields = [];
  if (nextTitle !== currentTitle) {
    changedFields.push("title");
  }
  if (nextProject !== currentProject) {
    changedFields.push("project");
  }
  if (!changedFields.length) {
    return {
      ok: true,
      status: 200,
      task: normalizedTask || existing,
      message: "Task already matches the requested text and project.",
    };
  }

  const transitionAt = nowUtc();
  const nextTask = {
    ...existing,
    title: nextTitle,
    project: nextProject,
    updated_at: transitionAt,
  };
  if (existing.task_intent && typeof existing.task_intent === "object") {
    nextTask.task_intent = {
      ...existing.task_intent,
      objective: nextTitle,
      project: nextProject,
    };
  }
  if (Object.prototype.hasOwnProperty.call(existing, "execution_task") || nextTitle !== currentTitle) {
    nextTask.execution_task = nextTitle;
  }
  nextTask.history = appendTaskHistory(
    nextTask,
    buildTaskHistoryEntry(nextTask, "edit", fromStatus, fromStatus, {
      at: transitionAt,
      note: `Updated pending task ${changedFields.join(" and ")} from the dashboard.`,
      project: nextProject,
      queueTask: nextTitle,
      changes: {
        ...(nextTitle !== currentTitle ? { title: { from: currentTitle, to: nextTitle } } : {}),
        ...(nextProject !== currentProject ? { project: { from: currentProject, to: nextProject } } : {}),
      },
    }),
  );
  payload.tasks[index] = nextTask;
  await writeTaskRegistryPayload(payload);
  await refreshPersistedMetrics(payload.tasks);
  await appendLog(`Updated pending task ${taskId}: ${currentProject}/${currentTitle} -> ${nextProject}/${nextTitle}`);
  return {
    ok: true,
    status: 200,
    task: nextTask,
    message: "Pending task updated.",
  };
}

async function transitionTaskRegistryItem(taskId, action) {
  const payload = await readTaskRegistryPayload();
  const index = payload.tasks.findIndex((task) => String(task.id || "").trim() === taskId);
  if (index === -1) {
    return { ok: false, status: 404, error: "Task was not found." };
  }

  const existing = payload.tasks[index];
  const normalizedTask = (await readTaskRegistry()).find((task) => task.id === taskId);
  const fromStatus = String((normalizedTask || existing).status || "pending_approval");

  if (action === "approve") {
    if (fromStatus !== "pending_approval") {
      return { ok: false, status: 409, error: "Only pending approval tasks can be approved." };
    }

    const status = await readStatus();
    const authHealth = await readCodexAuthHealth(status);
    if (authHealth.blocks_queue) {
      const authReason = authHealth.reason ? ` ${authHealth.reason}` : "";
      const cooldownNote = authHealth.remaining_seconds ? ` Retry after ${authHealth.remaining_seconds}s.` : "";
      await appendLog(`Rejected approval for ${taskId} because Codex auth is blocked.`, "WARN");
      return {
        ok: false,
        status: 409,
        error: `Codex auth is blocked. Resolve authentication before approving more work.${authReason}${cooldownNote}`,
      };
    }

    const transitionAt = nowUtc();
    const project = normalizeTaskProject(existing);
    const queueTask = taskExecutionText(existing);
    const executionProvider =
      normalizeProviderName(existing.execution_provider || existing.provider_selection?.selected) || "codex";
    const normalizedTaskIntent = normalizeTaskIntentRecord(
      normalizedTask || existing,
      queueTask,
      project,
      typeof existing.category === "string" ? existing.category : "code_quality",
    );
    const queueTaskIntent =
      normalizedTaskIntent || (existing.task_intent && typeof existing.task_intent === "object" ? existing.task_intent : null);
    if (!queueTask) {
      return { ok: false, status: 400, error: "Approved tasks need a non-empty title or execution task." };
    }

    const enqueueResult = await enqueueTask(project, queueTask);
    const duplicateQueue = enqueueResult.error === "Duplicate task rejected.";
    const queueStatus = duplicateQueue ? "already_queued" : "queued";
    if (!enqueueResult.ok && !duplicateQueue) {
      return enqueueResult;
    }

    const nextTask = {
      ...existing,
      project,
      status: "approved",
      approved_at: transitionAt,
      updated_at: transitionAt,
      execution_provider: executionProvider,
      execution_brief: buildApprovalExecutionBrief({
        approvedAt: transitionAt,
        project,
        queueTask,
        provider: executionProvider,
        queueStatus,
        taskIntent: normalizedTaskIntent,
      }),
      queue_handoff: {
        at: transitionAt,
        project,
        task: queueTask,
        status: queueStatus,
        provider: executionProvider,
        ...(queueTaskIntent ? { task_intent: queueTaskIntent } : {}),
      },
      ...(normalizedTaskIntent ? { task_intent: normalizedTaskIntent } : {}),
    };
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "approve", fromStatus, "approved", {
        at: transitionAt,
        note: duplicateQueue ? "Task was already queued or running." : "Task was enqueued after approval.",
        project,
        queueTask,
      }),
    );
    payload.tasks[index] = nextTask;
    await writeTaskRegistryPayload(payload);
    await refreshPersistedMetrics(payload.tasks);
    await appendLog(`Approved task ${taskId} for ${project}: ${queueTask}`);
    return {
      ok: true,
      status: 200,
      task: nextTask,
      message: duplicateQueue ? "Task approved and recognized as already queued." : "Task approved and queued.",
    };
  }

  if (action === "reject") {
    if (fromStatus !== "pending_approval") {
      return { ok: false, status: 409, error: "Only pending approval tasks can be rejected." };
    }

    const transitionAt = nowUtc();
    const nextTask = {
      ...existing,
      status: "rejected",
      rejected_at: transitionAt,
      updated_at: transitionAt,
    };
    nextTask.history = appendTaskHistory(
      nextTask,
      buildTaskHistoryEntry(nextTask, "reject", fromStatus, "rejected", {
        at: transitionAt,
        note: "Task was rejected from the dashboard.",
      }),
    );
    payload.tasks[index] = nextTask;
    await writeTaskRegistryPayload(payload);
    await refreshPersistedMetrics(payload.tasks);
    await appendLog(`Rejected task ${taskId}: ${nextTask.title}`);
    return {
      ok: true,
      status: 200,
      task: nextTask,
      message: "Task rejected.",
    };
  }

  return { ok: false, status: 400, error: "Unsupported task action." };
}

async function applyAutoApproveToTaskIds(taskIds) {
  const approved = [];
  const errors = [];
  const uniqueIds = [...new Set((Array.isArray(taskIds) ? taskIds : []).filter(Boolean))];

  for (const taskId of uniqueIds) {
    const result = await transitionTaskRegistryItem(taskId, "approve");
    if (result.ok) {
      approved.push(taskId);
    } else {
      errors.push({
        id: taskId,
        error: result.error || "Approval failed.",
      });
    }
  }

  const tasks = await readTaskRegistry();
  const tasksById = Object.fromEntries(
    tasks
      .filter((task) => uniqueIds.includes(task.id))
      .map((task) => [task.id, task]),
  );

  return {
    mode: "auto",
    attempted: uniqueIds.length,
    approved,
    errors,
    tasksById,
  };
}

async function readMetrics() {
  const [taskLog, queueCount, status, plannedTasks, settings] = await Promise.all([
    readText(PATHS.taskLog),
    queueTaskCount(),
    readStatus(),
    readTaskRegistry(),
    readDashboardSettings(),
  ]);
  const records = parseJsonLines(taskLog);
  const authHealth = await readCodexAuthHealth(status);
  const taskSummary = summarizeTaskRegistry(plannedTasks, authHealth);
  const total = records.length;
  const success = records.filter((record) => record.result === "SUCCESS").length;
  const failure = records.filter((record) => record.result === "FAILURE").length;
  const pendingApproval = taskSummary.byStatus.pending_approval;
  const approved = taskSummary.byStatus.approved;
  const successRate =
    total > 0 ? Number(((success / total) * 100).toFixed(1)) : 0;
  const averageDurationSeconds =
    total > 0
      ? Number(
          (
            records.reduce((sum, record) => sum + Number(record.duration_seconds || 0), 0) /
            Math.max(total, 1)
          ).toFixed(2),
        )
      : 0;
  const averageScore =
    total > 0
      ? Number(
          (
            records.reduce((sum, record) => sum + Number(record.score || 0), 0) / Math.max(total, 1)
          ).toFixed(2),
        )
      : 0;
  const lastRun = records.at(-1) || null;
  const lastFailed = [...records].reverse().find((record) => record.result === "FAILURE") || null;
  const liveWorkPanel = buildLiveWorkPanel(plannedTasks);
  return {
    total,
    success,
    failure,
    successRate,
    queued: queueCount,
    pendingApproval,
    approved,
    taskRegistryTotal: taskSummary.total,
    averageDurationSeconds,
    averageScore,
    currentState: status.state || "idle",
    lastRun,
    lastFailed,
    authHealth,
    settings,
    topPendingTask: taskSummary.topPendingTask,
    nextAction: taskSummary.nextAction,
    live_work_panel: liveWorkPanel,
  };
}

async function findLastFailedTask() {
  const taskLog = await readText(PATHS.taskLog);
  const records = parseJsonLines(taskLog);
  for (let index = records.length - 1; index >= 0; index -= 1) {
    const record = records[index];
    if (record.result === "FAILURE" && record.project && record.task) {
      return { project: record.project, task: record.task };
    }
  }
  return null;
}

async function appendLog(message, level = "INFO") {
  await fsp.appendFile(PATHS.logs, formatLogLine("dashboard", level, message), "utf8");
}

function sendJson(response, statusCode, payload) {
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  response.end(JSON.stringify(payload));
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.on("data", (chunk) => {
      body += chunk;
      if (body.length > 1024 * 1024) {
        reject(new Error("Payload too large"));
      }
    });
    request.on("end", () => resolve(body));
    request.on("error", reject);
  });
}

function localAddresses() {
  const networkInterfaces = os.networkInterfaces();
  const addresses = [];
  for (const entries of Object.values(networkInterfaces)) {
    for (const entry of entries || []) {
      if (entry.family === "IPv4" && !entry.internal) {
        addresses.push(entry.address);
      }
    }
  }
  return [...new Set(addresses)].sort();
}

async function enqueueTask(projectInput, taskInput) {
  const project = sanitizeProjectName(projectInput);
  const task = String(taskInput || "").trim();
  if (!project) {
    await appendLog("Rejected task submission with missing project.", "WARN");
    return { ok: false, status: 400, error: "Project is required." };
  }
  if (!task) {
    await appendLog(`Rejected empty task submission for ${project}.`, "WARN");
    return { ok: false, status: 400, error: "Task is required." };
  }

  const queued = await queueTaskCount();
  if (queued >= QUEUE_LIMIT) {
    await appendLog(`Rejected task for ${project} because queue limit ${QUEUE_LIMIT} was reached.`, "WARN");
    return { ok: false, status: 409, error: `Queue limit ${QUEUE_LIMIT} reached.` };
  }

  if (await taskExistsAnywhere(project, task)) {
    await appendLog(`Rejected duplicate task for ${project}: ${task}`, "WARN");
    return { ok: false, status: 409, error: "Duplicate task rejected." };
  }

  const projectDir = path.join(PATHS.projects, project);
  const queueFile = path.join(PATHS.queues, `${project}.txt`);
  const status = await readStatus();
  await fsp.mkdir(projectDir, { recursive: true });
  await fsp.appendFile(queueFile, `${task}\n`, "utf8");
  if (!["running", "retrying"].includes(String(status.state || "").toLowerCase())) {
    await writeStatus({
      ...status,
      state: "queued",
      project,
      task,
      note: `queued_at=${nowUtc()}`,
      updated_at: nowUtc(),
    });
  }
  await appendLog(`Queued task for ${project}: ${task}`);
  return { ok: true, status: 200, project, task };
}

async function handleApi(request, response, url) {
  if (request.method === "GET" && url.pathname === "/api/projects") {
    const projects = await listProjects();
    sendJson(response, 200, { projects });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/project-summaries") {
    const projects = await buildProjectSummaries();
    sendJson(response, 200, { projects });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/status") {
    const [status, addresses, strategy] = await Promise.all([
      readStatus(),
      Promise.resolve(localAddresses()),
      readStrategyHealth(),
    ]);
    const [authHealth, runtimeDashboardStatus] = await Promise.all([
      readCodexAuthHealth(status),
      readRuntimeDashboardStatus(status),
    ]);
    sendJson(response, 200, {
      ...status,
      ...runtimeDashboardStatus,
      authHealth,
      strategy,
      port: PORT,
      addresses,
      protocol: PROTOCOL,
    });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/settings") {
    const settings = await readDashboardSettings();
    sendJson(response, 200, settings);
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/settings") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const settings = await writeDashboardSettings({
        approval_mode: body.approval_mode || body.approvalMode || body.mode,
      });
      await appendLog(`Updated dashboard settings: approval_mode=${settings.approval_mode}`);
      sendJson(response, 200, { ok: true, settings, message: `Approval mode set to ${settings.approval_mode}.` });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/logs") {
    const limit = Math.max(20, Math.min(Number(url.searchParams.get("limit") || 200), 500));
    const logs = await readText(PATHS.logs);
    const lines = logs.split(/\r?\n/).filter(isStructuredLogLine).slice(-limit);
    sendJson(response, 200, { logs: lines.join("\n") });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/rules") {
    const rules = await readText(PATHS.rules);
    sendJson(response, 200, { rules });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/metrics") {
    const metrics = await readMetrics();
    sendJson(response, 200, metrics);
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/active-tasks") {
    const tasks = await readTaskRegistry();
    const active = tasks
      .filter((t) => {
        const state = String(t.execution?.state || "").toLowerCase();
        return state === "running" || state === "retrying";
      })
      .map((t) => {
        const ec = t.execution_context && typeof t.execution_context === "object" ? t.execution_context : {};
        return {
          id: t.id,
          title: t.title,
          provider: t.execution?.provider || "codex",
          lane: t.execution?.lane || "",
          attempt: t.execution?.attempt || 0,
          step_count: safeInteger(ec.step_count, 0),
          completed_steps: safeInteger(ec.completed_steps, 0),
          state: t.execution?.state || "",
        };
      });
    sendJson(response, 200, { active });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/task-registry") {
    const [tasks, status] = await Promise.all([readTaskRegistry(), readStatus()]);
    const authHealth = await readCodexAuthHealth(status);
    sendJson(response, 200, { tasks, summary: summarizeTaskRegistry(tasks, authHealth), authHealth });
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task-registry") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const result = await createTaskRegistryItem({
        project: body.project || body.newProject,
        task: body.task,
        title: body.title,
        category: body.category,
        confidence: body.confidence,
        effort: body.effort,
        impact: body.impact,
        reason: body.reason,
        contextHint: body.contextHint || body.context_hint,
        successCriteria: body.successCriteria || body.success_criteria,
        constraints: body.constraints,
        affectedFiles: body.affectedFiles || body.affected_files,
        executionProvider: body.executionProvider || body.execution_provider,
        autoApprove:
          typeof body.autoApprove === "boolean"
            ? body.autoApprove
            : (await readDashboardSettings()).approval_mode === "auto",
      });
      sendJson(response, result.status, result.ok ? result : { error: result.error });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task-registry/intake") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const result = await createTaskRegistryItemsFromPrompt({
        project: body.project || body.newProject,
        prompt: body.prompt || body.taskPrompt || body.task_prompt,
        reason: body.reason,
        executionProvider: body.executionProvider || body.execution_provider,
        autoApprove:
          typeof body.autoApprove === "boolean"
            ? body.autoApprove
            : (await readDashboardSettings()).approval_mode === "auto",
      });
      sendJson(response, result.status, result.ok ? result : { error: result.error });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task-registry/action") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const taskId = String(body.id || "").trim();
      const action = String(body.action || "").trim().toLowerCase();
      if (!taskId || !action) {
        sendJson(response, 400, { error: "Task id and action are required." });
        return;
      }
      const result = await transitionTaskRegistryItem(taskId, action);
      sendJson(response, result.status, result.ok ? result : { error: result.error });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task-registry/update") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const taskId = String(body.id || "").trim();
      if (!taskId) {
        sendJson(response, 400, { error: "Task id is required." });
        return;
      }
      const result = await updateTaskRegistryItem(taskId, {
        project: body.project,
        title: body.title,
      });
      sendJson(response, result.status, result.ok ? result : { error: result.error });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/queue") {
    const tasks = await readQueueTasks();
    sendJson(response, 200, { tasks });
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const result = await createTaskRegistryItem({
        project: body.project || body.newProject,
        task: body.task,
        title: body.title,
        category: body.category,
        confidence: body.confidence,
        effort: body.effort,
        impact: body.impact,
        contextHint: body.contextHint || body.context_hint,
        successCriteria: body.successCriteria || body.success_criteria,
        constraints: body.constraints,
        affectedFiles: body.affectedFiles || body.affected_files,
        executionProvider: body.executionProvider || body.execution_provider,
        reason:
          body.reason ||
          "Legacy direct queue submissions are routed into pending approval so work cannot bypass human review.",
        historyNote:
          "Legacy direct queue request was captured in the approval backlog instead of entering the live queue.",
        successMessage: "Direct queue is disabled. Task added to backlog for approval.",
        successStatus: 202,
        autoApprove:
          typeof body.autoApprove === "boolean"
            ? body.autoApprove
            : (await readDashboardSettings()).approval_mode === "auto",
      });
      sendJson(response, result.status, result.ok ? result : { error: result.error });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/retry-last-failed") {
    const candidate = await findLastFailedTask();
    if (!candidate) {
      sendJson(response, 404, { error: "No failed task is available to retry." });
      return;
    }

    const result = await enqueueTask(candidate.project, candidate.task);
    sendJson(response, result.status, result.ok ? result : { error: result.error });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/health") {
    sendJson(response, 200, { ok: true });
    return;
  }

  sendJson(response, 404, { error: "Not found" });
}

ensureStructure();

const requestHandler = async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host || "localhost"}`);
  if (url.pathname.startsWith("/api/")) {
    await handleApi(request, response, url);
    return;
  }

  const filePath = url.pathname === "/" ? path.join(PATHS.dashboard, "index.html") : null;
  if (!filePath) {
    response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    response.end("Not found");
    return;
  }

  const html = await readText(filePath);
  response.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
  });
  response.end(html);
};

const server = HTTPS_ENABLED
  ? https.createServer(readTlsCredentials(), requestHandler)
  : http.createServer(requestHandler);

server.listen(PORT, "0.0.0.0", () => {
  const addresses = localAddresses();
  const addressText = dashboardUrls(addresses).join(", ");
  fs.appendFileSync(
    PATHS.logs,
    formatLogLine("dashboard", "INFO", `Dashboard listening on ${addressText}`),
    "utf8",
  );
  console.log(`Dashboard listening on ${addressText}`);
});
