const formatNumber = new Intl.NumberFormat("en-US", {
  maximumFractionDigits: 0,
});

const formatDecimal = new Intl.NumberFormat("es-GT", {
  maximumFractionDigits: 2,
});

const state = {
  runs: [],
  selectedRunId: null,
};

async function loadJson(path) {
  if (window.location.protocol === "file:") {
    if (path.includes("latest")) return window.DASHBOARD_LATEST;
    if (path.includes("runs")) return window.DASHBOARD_RUNS;
  }

  const response = await fetch(path, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`Could not load ${path}`);
  }
  return response.json();
}

function pct(value) {
  return `${value > 0 ? "+" : ""}${formatDecimal.format(value)}%`;
}

function displayZafra(value) {
  return String(value).replace("_", "-");
}

function setText(id, value) {
  document.getElementById(id).textContent = value;
}

function selectedRun() {
  return state.runs.find((run) => run.id === state.selectedRunId) ?? state.runs[0];
}

function populateRunPicker() {
  const picker = document.getElementById("runPicker");
  picker.innerHTML = "";
  state.runs.forEach((run) => {
    const option = document.createElement("option");
    option.value = run.id;
    option.textContent = `${run.label} - ${run.updated_at}`;
    picker.appendChild(option);
  });
  picker.value = state.selectedRunId;
  picker.addEventListener("change", () => {
    state.selectedRunId = picker.value;
    render();
  });
}

function renderKpis(run) {
  const coverage = run.coverage;
  const forecast = run.forecast;
  const coveragePct = coverage.total_candidate_lots
    ? (coverage.eligible_lots / coverage.total_candidate_lots) * 100
    : 0;

  setText("statusBadge", run.status);
  setText("updatedAt", `Actualizado ${run.updated_at}`);
  setText("aggregateValue", formatNumber.format(forecast.predicted_aggregate_tch_sum));
  setText(
    "rangeText",
    `Rango preliminar P10-P90: ${formatNumber.format(forecast.p10_sum)} - ${formatNumber.format(
      forecast.p90_sum,
    )}`,
  );
  setText("eligibleLots", formatNumber.format(coverage.eligible_lots));
  setText(
    "coverageText",
    `${formatNumber.format(coverage.pending_lots)} pendientes de ${formatNumber.format(
      coverage.total_candidate_lots,
    )} candidatos`,
  );
  setText("targetZafra", displayZafra(run.target_zafra));
  setText("modelName", run.model);
  setText("coveragePercent", `${formatDecimal.format(coveragePct)}%`);
  setText("pendingLots", formatNumber.format(coverage.pending_lots));
  setText("totalLots", formatNumber.format(coverage.total_candidate_lots));

  document.getElementById("coverageFill").style.width = `${Math.min(100, coveragePct)}%`;
}

function renderBarList(containerId, items, options = {}) {
  const container = document.getElementById(containerId);
  container.innerHTML = "";
  const max = Math.max(...items.map((item) => Math.abs(item.value)), 1);

  items.forEach((item) => {
    const row = document.createElement("div");
    row.className = options.snapshot ? "snapshot-row" : "error-row";

    const label = document.createElement("strong");
    label.textContent = item.label;

    const bar = document.createElement("div");
    bar.className = "bar";
    if (item.value < 0) bar.classList.add("negative");
    if (Math.abs(item.value) >= (options.warningAt ?? 5)) bar.classList.add("warning");

    const fill = document.createElement("span");
    fill.style.width = `${Math.max(3, (Math.abs(item.value) / max) * 100)}%`;
    bar.appendChild(fill);

    const value = document.createElement("span");
    value.className = "value-pill";
    if (item.value < 0) value.classList.add("negative");
    if (Math.abs(item.value) >= (options.warningAt ?? 5)) value.classList.add("warning");
    value.textContent = options.signed ? pct(item.value) : `${formatDecimal.format(item.value)}%`;

    row.append(label, bar, value);
    container.appendChild(row);
  });
}

function renderDrivers(run) {
  const container = document.getElementById("drivers");
  container.innerHTML = "";
  const top = run.top_drivers.slice(0, 8);
  const max = Math.max(...top.map((item) => item.importance), 1);

  top.forEach((item) => {
    const row = document.createElement("div");
    row.className = "driver-row";

    const label = document.createElement("strong");
    label.textContent = item.label;

    const bar = document.createElement("div");
    bar.className = "bar";
    const fill = document.createElement("span");
    fill.style.width = `${(item.importance / max) * 100}%`;
    bar.appendChild(fill);

    const value = document.createElement("span");
    value.className = "value-pill";
    value.textContent = formatDecimal.format(item.importance);

    row.append(label, bar, value);
    container.appendChild(row);
  });
}

function drawEvolution(run) {
  const canvas = document.getElementById("evolutionChart");
  const ctx = canvas.getContext("2d");
  const ratio = window.devicePixelRatio || 1;
  const width = canvas.clientWidth;
  const height = 230;
  canvas.width = width * ratio;
  canvas.height = height * ratio;
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);

  const history = run.history;
  if (!history.length) return;

  const pad = { left: 48, right: 24, top: 18, bottom: 42 };
  const xs = history.map((_, index) =>
    history.length === 1
      ? width / 2
      : pad.left + (index / (history.length - 1)) * (width - pad.left - pad.right),
  );
  const values = history.flatMap((item) => [item.p10_sum, item.predicted_aggregate_tch_sum, item.p90_sum]);
  const min = Math.min(...values) * 0.985;
  const max = Math.max(...values) * 1.015;
  const y = (value) => pad.top + ((max - value) / (max - min)) * (height - pad.top - pad.bottom);

  ctx.strokeStyle = "#d9ddd6";
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(pad.left, height - pad.bottom);
  ctx.lineTo(width - pad.right, height - pad.bottom);
  ctx.stroke();

  ctx.fillStyle = "rgba(47, 111, 159, 0.14)";
  ctx.beginPath();
  history.forEach((item, index) => {
    const method = index === 0 ? "moveTo" : "lineTo";
    ctx[method](xs[index], y(item.p90_sum));
  });
  [...history].reverse().forEach((item, reverseIndex) => {
    const index = history.length - 1 - reverseIndex;
    ctx.lineTo(xs[index], y(item.p10_sum));
  });
  ctx.closePath();
  ctx.fill();

  ctx.strokeStyle = "#2f7d55";
  ctx.lineWidth = 3;
  ctx.beginPath();
  history.forEach((item, index) => {
    const method = index === 0 ? "moveTo" : "lineTo";
    ctx[method](xs[index], y(item.predicted_aggregate_tch_sum));
  });
  ctx.stroke();

  ctx.fillStyle = "#2f7d55";
  history.forEach((item, index) => {
    ctx.beginPath();
    ctx.arc(xs[index], y(item.predicted_aggregate_tch_sum), 4, 0, Math.PI * 2);
    ctx.fill();
  });

  ctx.fillStyle = "#66727f";
  ctx.font = "12px Inter, sans-serif";
  ctx.textAlign = "center";
  history.forEach((item, index) => {
    ctx.fillText(item.label, xs[index], height - 16);
  });

  ctx.textAlign = "left";
  ctx.fillText(formatNumber.format(max), 0, pad.top + 4);
  ctx.fillText(formatNumber.format(min), 0, height - pad.bottom + 4);
}

function render() {
  const run = selectedRun();
  renderKpis(run);
  renderBarList(
    "walkForwardList",
    run.walk_forward_errors.map((item) => ({
      label: item.zafra,
      value: item.abs_error_pct,
    })),
    { warningAt: 5 },
  );
  renderBarList(
    "snapshotList",
    run.external_snapshot_errors.map((item) => ({
      label: `${item.snapshot_day}d`,
      value: item.error_pct,
    })),
    { signed: true, warningAt: 5, snapshot: true },
  );
  renderDrivers(run);
  drawEvolution(run);
}

async function boot() {
  const latest = await loadJson("./data/latest.json");
  const runsPayload = await loadJson("./data/runs.json");
  state.runs = runsPayload.runs;
  state.selectedRunId = latest.current_run_id;
  populateRunPicker();
  render();
  window.addEventListener("resize", () => render());
}

boot().catch((error) => {
  document.body.innerHTML = `<main class="shell"><section class="panel"><h1>No se pudieron cargar los datos del dashboard</h1><p class="muted">${error.message}</p></section></main>`;
});
