/* Audience-facing tracking page: create a shipment, then follow it live. */

const createCard = document.getElementById("create-card");
const resultCard = document.getElementById("result-card");
const createForm = document.getElementById("create-form");
const createButton = document.getElementById("create-button");
const lookupForm = document.getElementById("lookup-form");

let tracking = null;
let pollTimer = null;

function showResult(number) {
  tracking = number;
  document.getElementById("result-tracking").textContent = number;
  createCard.classList.add("hidden");
  resultCard.classList.remove("hidden");
  history.replaceState(null, "", `/track?n=${encodeURIComponent(number)}`);
  poll();
  if (pollTimer) clearInterval(pollTimer);
  pollTimer = setInterval(poll, window.REFRESH_MS || 3000);
}

function renderShipment(data) {
  const bar = document.getElementById("result-bar");
  bar.style.width = `${Number(data.progress_percent) || 0}%`;
  bar.classList.toggle("done", data.status === "DELIVERED");

  const statusLine = document.getElementById("result-status");
  statusLine.textContent = data.status_narrative;
  statusLine.className = `status-line status status-${data.status}`;

  document.getElementById("result-route").textContent =
    `${data.origin} → ${data.destination}`;
  document.getElementById("result-carrier").textContent =
    `${data.carrier_name} (${data.carrier_code})`;

  const scans = data.scans || [];
  if (scans.length) {
    document.getElementById("result-location").textContent = scans[0].location;
  }

  document.getElementById("result-scans").innerHTML = scans.length
    ? scans.map((scan) => `
        <li>
          <span class="scan-type">${escapeHTML(scan.scan_type.replace(/_/g, " "))}</span>
          — ${escapeHTML(scan.location)}
          <span class="scan-meta">
            ${escapeHTML(relativeTime(scan.occurred_at))} ·
            scanned by ${escapeHTML(scan.worker_host)} (${escapeHTML(scan.worker_site)})
          </span>
        </li>`).join("")
    : `<li class="hint">No scans yet — the worker tier picks this up within a few seconds.</li>`;
}

async function poll() {
  if (!tracking) return;
  try {
    renderShipment(await getJSON(`/api/shipments/${encodeURIComponent(tracking)}`));
    clearBanner();
  } catch (err) {
    if (err.status === 404) {
      showBanner(`No shipment found with number ${tracking}.`, "warn");
    } else {
      showBanner(`Cannot reach the tracking service right now — ${err.message}`, "error");
    }
  }
}

createForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  createButton.disabled = true;
  clearBanner();

  const form = new FormData(createForm);
  const body = {
    origin: form.get("origin"),
    destination: form.get("destination"),
    description: form.get("description") || "General freight",
    weight_kg: Number(form.get("weight_kg")) || 1,
    created_by: form.get("created_by") || "attendee",
  };

  try {
    const created = await getJSON("/api/shipments", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    showResult(created.tracking_number);
  } catch (err) {
    if (err.status === 429) {
      showBanner(err.message, "warn");
    } else {
      showBanner(`Could not create the shipment — ${err.message}`, "error");
    }
  } finally {
    createButton.disabled = false;
  }
});

lookupForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const value = new FormData(lookupForm).get("tracking").trim().toUpperCase();
  if (value) showResult(value);
});

document.getElementById("another-button").addEventListener("click", () => {
  if (pollTimer) clearInterval(pollTimer);
  tracking = null;
  resultCard.classList.add("hidden");
  createCard.classList.remove("hidden");
  history.replaceState(null, "", "/track");
});

if (window.PREFILL) showResult(window.PREFILL);
