const http = require("http");
const fs = require("fs");
const fsp = fs.promises;
const os = require("os");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const PORT = Number(process.env.DASHBOARD_PORT || 3000);
const QUEUE_LIMIT = Number(process.env.QUEUE_LIMIT || 20);
const PATHS = {
  dashboard: __dirname,
  projects: path.join(ROOT, "projects"),
  queues: path.join(ROOT, "queues"),
  logs: path.join(ROOT, "codex-logs", "system.log"),
  rules: path.join(ROOT, "codex-learning", "rules.md"),
  tasks: path.join(ROOT, "codex-memory", "tasks.log"),
  status: path.join(ROOT, "status.txt"),
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
  ensureFile(PATHS.rules, "# Learned Rules\n\n");
  ensureFile(PATHS.tasks, "");
  ensureFile(
    PATHS.status,
    "state=IDLE\nproject=\ntask=\nlast_result=NONE\nnote=Dashboard initialized\nupdated_at=\n",
  );
}

function formatLogLine(agent, level, message) {
  return `[${new Date().toISOString()}] [${agent}] ${level}: ${message}\n`;
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

async function readText(filePath) {
  try {
    return await fsp.readFile(filePath, "utf8");
  } catch {
    return "";
  }
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

async function readMetrics() {
  const [taskLog, queueCount, status] = await Promise.all([
    readText(PATHS.tasks),
    queueTaskCount(),
    readStatus(),
  ]);
  const records = parseJsonLines(taskLog);
  const total = records.length;
  const success = records.filter((record) => record.result === "SUCCESS").length;
  const failure = records.filter((record) => record.result === "FAILURE").length;
  const averageScore =
    total > 0
      ? Number(
          (
            records.reduce((sum, record) => sum + Number(record.score || 0), 0) / Math.max(total, 1)
          ).toFixed(2),
        )
      : 0;
  const lastRun = records.at(-1) || null;
  return {
    total,
    success,
    failure,
    queued: queueCount,
    averageScore,
    currentState: status.state || "IDLE",
    lastRun,
  };
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
  await fsp.mkdir(projectDir, { recursive: true });
  await fsp.appendFile(queueFile, `${task}\n`, "utf8");
  await appendLog(`Queued task for ${project}: ${task}`);
  return { ok: true, status: 200, project, task };
}

async function handleApi(request, response, url) {
  if (request.method === "GET" && url.pathname === "/api/projects") {
    const projects = await listProjects();
    sendJson(response, 200, { projects });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/status") {
    const [status, addresses] = await Promise.all([readStatus(), Promise.resolve(localAddresses())]);
    sendJson(response, 200, { ...status, port: PORT, addresses });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/logs") {
    const limit = Math.max(20, Math.min(Number(url.searchParams.get("limit") || 200), 500));
    const logs = await readText(PATHS.logs);
    const lines = logs.split(/\r?\n/).filter(Boolean).slice(-limit);
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

  if (request.method === "GET" && url.pathname === "/api/queue") {
    const tasks = await readQueueTasks();
    sendJson(response, 200, { tasks });
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task") {
    try {
      const rawBody = await readRequestBody(request);
      const body = JSON.parse(rawBody || "{}");
      const result = await enqueueTask(body.project || body.newProject, body.task);
      sendJson(response, result.status, result.ok ? result : { error: result.error });
    } catch (error) {
      sendJson(response, 400, { error: error.message || "Invalid request body." });
    }
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/health") {
    sendJson(response, 200, { ok: true });
    return;
  }

  sendJson(response, 404, { error: "Not found" });
}

ensureStructure();

const server = http.createServer(async (request, response) => {
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
});

server.listen(PORT, "0.0.0.0", () => {
  const addresses = localAddresses();
  const addressText = addresses.length ? addresses.map((ip) => `http://${ip}:${PORT}`).join(", ") : "http://localhost:3000";
  fs.appendFileSync(
    PATHS.logs,
    formatLogLine("dashboard", "INFO", `Dashboard listening on ${addressText}`),
    "utf8",
  );
  console.log(`Dashboard listening on ${addressText}`);
});
