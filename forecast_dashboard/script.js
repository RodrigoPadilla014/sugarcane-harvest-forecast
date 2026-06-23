const formatNumber = new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 });
const formatDecimal = new Intl.NumberFormat("es-GT", { maximumFractionDigits: 2 });

const state = {
  runs: [],
  forecastSnapshots: [],
  selectedRunId: null,
};

function valueOr(value, fallback) {
  return value == null ? fallback : value;
}

async function loadJson(path) {
  if (window.location.protocol === "file:") {
    if (path.includes("latest")) return window.DASHBOARD_LATEST;
    if (path.includes("runs")) return window.DASHBOARD_RUNS;
  }
  const response = await fetch(path, { cache: "no-store" });
  if (!response.ok) throw new Error(`No se pudo cargar ${path}`);
  return response.json();
}

function pct(value) {
  return `${value > 0 ? "+" : ""}${formatDecimal.format(value)}%`;
}

function displayZafra(value) {
  return String(value).replace("_", "-");
}

function forecastValue(forecast, key, fallbackKey) {
  return valueOr(forecast[key], valueOr(forecast[fallbackKey], 0));
}

function hasForecastValue(forecast, key, fallbackKey) {
  return forecast[key] != null || forecast[fallbackKey] != null;
}

function setText(id, value) {
  const element = document.getElementById(id);
  if (element) element.textContent = value;
}

function selectedRun() {
  return state.runs.find((run) => run.id === state.selectedRunId) || state.runs[0];
}

function populateRunPicker() {
  const picker = document.getElementById("runPicker");
  picker.innerHTML = "";
  state.runs.forEach((run) => {
    const option = document.createElement("option");
    option.value = run.id;
    option.textContent = `${run.label} - ${run.status}`;
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
  setText("aggregateValue", formatNumber.format(forecastValue(forecast, "predicted_metric_tons", "predicted_aggregate_tch_sum")));

  if (hasForecastValue(forecast, "p10_metric_tons", "p10_sum") && hasForecastValue(forecast, "p90_metric_tons", "p90_sum")) {
    setText(
      "rangeText",
      `Rango nativo P10-P90: ${formatNumber.format(forecastValue(forecast, "p10_metric_tons", "p10_sum"))} - ${formatNumber.format(
        forecastValue(forecast, "p90_metric_tons", "p90_sum"),
      )} TM`,
    );
  } else {
    setText("rangeText", "Rango nativo no calibrado para este modelo shadow.");
  }

  setText("eligibleArea", `${formatNumber.format(valueOr(forecast.area_sum, 0))} ha`);
  setText("eligibleLots", formatNumber.format(coverage.eligible_lots));
  setText(
    "meanTch",
    formatDecimal.format(valueOr(forecast.predicted_tch_mean, forecast.predicted_aggregate_tch_sum / Math.max(1, coverage.eligible_lots))),
  );
  setText(
    "coverageText",
    `${formatNumber.format(coverage.pending_lots)} pendientes de ${formatNumber.format(coverage.total_candidate_lots)} candidatos esperados`,
  );
  setText("targetZafra", displayZafra(run.target_zafra));
  setText("modelName", run.model);
  setText("coveragePercent", `${formatDecimal.format(coveragePct)}%`);
  setText("pendingLots", formatNumber.format(coverage.pending_lots));
  setText("totalLots", formatNumber.format(coverage.total_candidate_lots));
  document.getElementById("coverageFill").style.width = `${Math.min(100, coveragePct)}%`;
}

function renderUncertainty(run) {
  const uncertainty = run.uncertainty || {};
  const native = uncertainty.native_asymmetric || {};
  const practical = uncertainty.practical_plus_minus || {};

  setText("testingNote", run.testing_note || "Modelo en monitoreo.");

  if (native.available) {
    setText("nativeRange", `${formatNumber.format(native.lower_tm)} - ${formatNumber.format(native.upper_tm)} TM`);
    setText("nativeRangeNote", native.coverage_note || "Rango nativo del modelo.");
  } else {
    setText("nativeRange", "No disponible");
    setText("nativeRangeNote", native.coverage_note || "No calibrado para este modelo.");
  }

  if (practical.available && practical.lower_tm != null && practical.upper_tm != null) {
    const centerTm = valueOr(practical.center_tm, run.forecast.predicted_metric_tons);
    const plusMinusTm = valueOr(practical.plus_minus_tm, Math.max(centerTm - practical.lower_tm, practical.upper_tm - centerTm));
    setText("practicalRange", `${formatDecimal.format(run.forecast.predicted_area_weighted_tch)} +/-${formatDecimal.format(practical.margin_tch)} TCH`);
    setText(
      "practicalRangeNote",
      `Equivale a ${formatNumber.format(centerTm)} +/-${formatNumber.format(plusMinusTm)} TM (${formatNumber.format(
        practical.lower_tm,
      )} - ${formatNumber.format(practical.upper_tm)} TM). ${practical.lot_range_note || ""}`,
    );
  } else {
    setText("practicalRange", "No calibrado");
    setText("practicalRangeNote", practical.lot_range_note || "Usar solo como shadow hasta calibrarlo.");
  }
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
    if (Math.abs(item.value) >= valueOr(options.warningAt, 5)) bar.classList.add("warning");
    const fill = document.createElement("span");
    fill.style.width = `${Math.max(3, (Math.abs(item.value) / max) * 100)}%`;
    bar.appendChild(fill);
    const value = document.createElement("span");
    value.className = "value-pill";
    if (item.value < 0) value.classList.add("negative");
    if (Math.abs(item.value) >= valueOr(options.warningAt, 5)) value.classList.add("warning");
    value.textContent = options.signed ? pct(item.value) : `${formatDecimal.format(item.value)}%`;
    row.append(label, bar, value);
    container.appendChild(row);
  });
}

function renderDrivers(run) {
  const container = document.getElementById("drivers");
  container.innerHTML = "";
  const top = run.top_drivers.slice(0, 8);
  if (!top.length) {
    const empty = document.createElement("p");
    empty.className = "muted";
    empty.textContent = "Variables principales no publicadas para este modelo shadow.";
    container.appendChild(empty);
    return;
  }
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

function prepareCanvas(canvasId) {
  const canvas = document.getElementById(canvasId);
  const ctx = canvas.getContext("2d");
  const ratio = window.devicePixelRatio || 1;
  const width = canvas.clientWidth || 520;
  const height = 230;
  canvas.width = width * ratio;
  canvas.height = height * ratio;
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);
  return { ctx, width, height };
}

function drawAxes(ctx, width, height, pad) {
  ctx.strokeStyle = "#d9ddd6";
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(pad.left, height - pad.bottom);
  ctx.lineTo(width - pad.right, height - pad.bottom);
  ctx.stroke();
}

function drawForecastHistory(run) {
  const { ctx, width, height } = prepareCanvas("evolutionChart");
  const snapshots = state.forecastSnapshots;
  if (!snapshots.length) return;
  const pad = { left: 58, right: 24, top: 18, bottom: 54 };
  const values = snapshots.map((item) => item.predicted_metric_tons);
  const min = Math.min(...values) * 0.975;
  const max = Math.max(...values) * 1.025;
  const y = (value) => pad.top + ((max - value) / Math.max(1, max - min)) * (height - pad.top - pad.bottom);
  const x = (index) => (snapshots.length === 1 ? width / 2 : pad.left + (index / (snapshots.length - 1)) * (width - pad.left - pad.right));
  drawAxes(ctx, width, height, pad);
  ctx.strokeStyle = "#b8c0b7";
  ctx.lineWidth = 2;
  ctx.setLineDash([4, 5]);
  ctx.beginPath();
  snapshots.forEach((item, index) => ctx[index === 0 ? "moveTo" : "lineTo"](x(index), y(item.predicted_metric_tons)));
  ctx.stroke();
  ctx.setLineDash([]);
  snapshots.forEach((item, index) => {
    const isSelected = item.model_id === run.id;
    const isArchived = !item.active;
    ctx.fillStyle = isSelected ? "#2f7d55" : isArchived ? "#98a19a" : "#2f6f9f";
    ctx.beginPath();
    ctx.arc(x(index), y(item.predicted_metric_tons), isSelected ? 6 : 4, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = "#66727f";
    ctx.font = "11px Inter, sans-serif";
    ctx.textAlign = "center";
    ctx.fillText(item.label, x(index), height - 28);
    ctx.fillText(isArchived ? "V9" : item.status.replace("Forecast ", ""), x(index), height - 13);
  });
  ctx.fillStyle = "#66727f";
  ctx.font = "12px Inter, sans-serif";
  ctx.textAlign = "left";
  ctx.fillText(formatNumber.format(max), 0, pad.top + 4);
  ctx.fillText(formatNumber.format(min), 0, height - pad.bottom + 4);
}

function drawZafraTrend(run) {
  const { ctx, width, height } = prepareCanvas("zafraTrendChart");
  const trend = run.volume_trend || [];
  if (!trend.length) return;
  const pad = { left: 58, right: 24, top: 18, bottom: 48 };
  const values = trend.map((item) => item.weighted_tch);
  const min = Math.min(...values) - 2;
  const max = Math.max(...values) + 2;
  const y = (value) => pad.top + ((max - value) / Math.max(1, max - min)) * (height - pad.top - pad.bottom);
  const x = (index) => (trend.length === 1 ? width / 2 : pad.left + (index / (trend.length - 1)) * (width - pad.left - pad.right));
  drawAxes(ctx, width, height, pad);
  ctx.strokeStyle = "#2f7d55";
  ctx.lineWidth = 3;
  ctx.beginPath();
  trend.forEach((item, index) => ctx[index === 0 ? "moveTo" : "lineTo"](x(index), y(item.weighted_tch)));
  ctx.stroke();
  trend.forEach((item, index) => {
    const isPrediction = item.kind === "model_prediction";
    ctx.fillStyle = isPrediction ? "#b36b19" : "#2f7d55";
    ctx.beginPath();
    ctx.arc(x(index), y(item.weighted_tch), isPrediction ? 6 : 4, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = "#66727f";
    ctx.font = "11px Inter, sans-serif";
    ctx.textAlign = "center";
    ctx.fillText(item.label.replace("20", ""), x(index), height - 20);
    ctx.fillText(`${formatDecimal.format(item.weighted_tch)} TCH`, x(index), height - 6);
  });
  ctx.fillStyle = "#66727f";
  ctx.font = "12px Inter, sans-serif";
  ctx.textAlign = "left";
  ctx.fillText(`${formatDecimal.format(max)} TCH`, 0, pad.top + 4);
  ctx.fillText(`${formatDecimal.format(min)} TCH`, 0, height - pad.bottom + 4);
}

function renderArchivedSnapshots() {
  const container = document.getElementById("archivedSnapshots");
  container.innerHTML = "";
  state.forecastSnapshots.filter((snapshot) => !snapshot.active).forEach((snapshot) => {
    const card = document.createElement("div");
    card.className = "archive-row";
    card.innerHTML = `
      <div>
        <strong>${snapshot.model_label}</strong>
        <span>${snapshot.label} - ${snapshot.status}</span>
      </div>
      <div>
        <strong>${formatNumber.format(snapshot.predicted_metric_tons)} TM</strong>
        <span>${formatNumber.format(snapshot.eligible_lots)} lotes - ${formatNumber.format(snapshot.area)} ha</span>
      </div>
    `;
    container.appendChild(card);
  });
}

function render() {
  const run = selectedRun();
  renderKpis(run);
  renderUncertainty(run);
  renderBarList("walkForwardList", run.walk_forward_errors.map((item) => ({ label: item.zafra, value: item.abs_error_pct })), { warningAt: 5 });
  renderBarList("snapshotList", run.external_snapshot_errors.map((item) => ({ label: `${item.snapshot_day}d`, value: item.error_pct })), {
    signed: true,
    warningAt: 5,
    snapshot: true,
  });
  renderDrivers(run);
  renderArchivedSnapshots();
  drawForecastHistory(run);
  drawZafraTrend(run);
}

async function boot() {
  const latest = await loadJson("./data/latest.json");
  const runsPayload = await loadJson("./data/runs.json");
  state.runs = runsPayload.runs;
  state.forecastSnapshots = runsPayload.forecast_snapshots || [];
  state.selectedRunId = latest.current_run_id;
  populateRunPicker();
  render();
  window.addEventListener("resize", () => render());
}

boot().catch((error) => {
  document.body.innerHTML = `<main class="shell"><section class="panel"><h1>No se pudieron cargar los datos del dashboard</h1><p class="muted">${error.message}</p></section></main>`;
});
