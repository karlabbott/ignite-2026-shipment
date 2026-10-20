/* Infrastructure commands run only on the private, outbound-polling runner. */

const presenterKey = document.getElementById("presenter-key");
const savePresenterKey = document.getElementById("save-presenter-key");
const forgetPresenterKey = document.getElementById("forget-presenter-key");
const openVoting = document.getElementById("open-voting");
const closeVoting = document.getElementById("close-voting");
const injectFault = document.getElementById("inject-fault");
const injectionStatus = document.getElementById("injection-status");
const injectionReason = document.getElementById("injection-disabled-reason");
const releaseGolden = document.getElementById("release-golden");
const goldenStatus = document.getElementById("golden-shipment-status");
let goldenShipment = null;
let refreshingGolden = false;
let goldenRequest = 0;
let presenterPoll = null;
let presenterInjection = null;
let changingPoll = false;
let pollRequest = 0;
let pollReadFailed = false;
let refreshingPoll = false;
let savingPresenterKey = false;
let activePresenterKey = "";
let hasStoredPresenterKey = false;
const PRESENTER_KEY_STORAGE = "zava-presenter-key";

function needsPollReset() {
  return presenterPoll && (presenterPoll.state === "injected" ||
    presenterInjection && presenterInjection.state === "failed");
}

function updateVotingControls() {
  const hasKey = Boolean(activePresenterKey);
  savePresenterKey.disabled = changingPoll || savingPresenterKey || !presenterKey.value.trim();
  forgetPresenterKey.disabled = changingPoll || savingPresenterKey ||
    (!presenterKey.value.trim() && !hasStoredPresenterKey);
  const state = presenterPoll && presenterPoll.state;
  const unresolved = presenterInjection &&
    ["queued", "running"].includes(presenterInjection.state) &&
    !["recovered", "closed"].includes(state);
  openVoting.disabled = changingPoll || !hasKey || !presenterPoll ||
    state === "open" || unresolved || (state === "injected" && !presenterInjection);
  openVoting.title = needsPollReset()
    ? "Start fresh voting without changing the infrastructure." : "";
  closeVoting.disabled = changingPoll || !hasKey || state !== "open";
  releaseGolden.disabled = changingPoll || savingPresenterKey || !hasKey ||
    !goldenShipment || !goldenShipment.is_held;
  releaseGolden.title = !hasKey ? "Save a valid presenter key to release the shipment."
    : goldenShipment && !goldenShipment.is_held ? "The golden shipment is no longer held." : "";
  const reason = changingPoll ? "Waiting for the current voting action to finish."
    : !hasKey ? "Save a valid presenter key to unlock the controls."
    : !presenterPoll ? "Waiting for voting status."
    : state !== "locked" ? "Close voting before injecting the selected fault."
    : !presenterPoll.winner_code ? "This poll has no selected winner."
    : !presenterInjection ? "Waiting for an authenticated private-runner status."
    : !presenterInjection.runner_online ? "The private runner is offline."
    : presenterInjection.state ? "This poll already has an injection request. See its status below."
    : "";
  injectFault.disabled = Boolean(reason);
  injectFault.title = reason || "Inject this poll's winning fault";
  injectionReason.textContent = reason;
  injectionReason.hidden = !reason;
}

async function refreshGoldenShipment() {
  if (changingPoll || refreshingGolden) return;
  refreshingGolden = true;
  const request = ++goldenRequest;
  try {
    const presentation = await getJSON("/api/presentation?limit=1", {
      cache: "no-store", signal: AbortSignal.timeout(10000),
    });
    if (request !== goldenRequest) return;
    goldenShipment = presentation.golden;
    goldenStatus.textContent = !goldenShipment ? "No golden shipment configured."
      : `${goldenShipment.tracking_number}: ${goldenShipment.status} - ${
        goldenShipment.is_held ? "held"
          : goldenShipment.status === "DELIVERED" ? "delivered" : "released; awaiting worker delivery"}.`;
  } catch (err) {
    if (request !== goldenRequest) return;
    goldenShipment = null;
    goldenStatus.textContent = `Could not read golden shipment status - ${err.message}`;
  } finally {
    refreshingGolden = false;
    updateVotingControls();
  }
}

async function releaseGoldenShipment() {
  if (releaseGolden.disabled || !window.confirm(
    `Release ${goldenShipment.tracking_number}? The hold will be removed and the worker can complete delivery.`,
  )) return;
  changingPoll = true;
  ++pollRequest;
  ++goldenRequest;
  goldenShipment = null;
  goldenStatus.textContent = "Releasing the golden shipment...";
  updateVotingControls();
  try {
    const result = await getJSON("/api/presentation/golden/release", {
      method: "POST", headers: {"x-zava-presenter-key": activePresenterKey},
      signal: AbortSignal.timeout(10000),
    });
    if (!result.released) throw new Error("The API did not confirm release.");
    goldenStatus.textContent = `${result.tracking_number}: released. Checking worker delivery status...`;
    clearBanner();
  } catch (err) {
    goldenStatus.textContent = `Release was not confirmed - ${err.message}`;
    showBanner(`Could not confirm golden shipment release - ${err.message}`, "error");
  } finally {
    changingPoll = false;
    updateVotingControls();
    refreshGoldenShipment();
  }
}

function renderInjectionStatus(injection) {
  presenterInjection = injection;
  injectionStatus.textContent = {
    queued: "Fault requested. Waiting for the private runner.",
    running: injection.runner_online
      ? "Private runner is injecting the winning fault."
      : "Injection was claimed, but the runner is offline. Inspect its log; do not retry blindly.",
    succeeded: "Winning fault injected. You can open fresh voting; it does not repair the fault.",
    failed: "Injection failed or expired. A partial fault may remain. Inspect the private runner log before continuing.",
  }[injection.state] || (injection.runner_online
    ? "Private runner online. Close voting to select a fault, then explicitly inject it."
    : "Private runner offline. Injection is unavailable.");
  updateVotingControls();
}

function renderPresenterPoll(poll) {
  presenterPoll = poll;
  document.getElementById("presenter-poll-state").textContent = {
    open: "Voting open",
    locked: "Voting closed",
    injected: "Fault injected",
    recovered: "Service recovered",
    closed: "No open voting",
  }[poll.state] || poll.state;
  document.getElementById("presenter-poll-count").textContent = poll.poll_id
    ? `Poll ${poll.poll_id} - ${poll.total_votes} vote${poll.total_votes === 1 ? "" : "s"}`
    : "Ready to open a poll";
  const winner = poll.state !== "open" && poll.choices.find(
    (choice) => choice.code === poll.winner_code,
  );
  document.getElementById("presenter-poll-winner").textContent = winner
    ? `Selected: ${winner.label}` : "";
  updateVotingControls();
}

async function refreshPresenterPoll() {
  if (changingPoll || refreshingPoll || savingPresenterKey) return;
  refreshingPoll = true;
  const request = ++pollRequest;
  try {
    const poll = await getJSON("/api/poll", {
      cache: "no-store", signal: AbortSignal.timeout(10000),
    });
    if (request !== pollRequest) return;
    if (!presenterPoll || presenterPoll.poll_id !== poll.poll_id) presenterInjection = null;
    renderPresenterPoll(poll);
    if (pollReadFailed) clearBanner();
    pollReadFailed = false;
    const key = activePresenterKey;
    if (!key) {
      injectionStatus.textContent = "Save your presenter key to check the private runner.";
      return;
    }
    try {
      const injection = await getJSON(
        `/api/presenter/polls/${poll.poll_id || 0}/injection`,
        {headers: {"x-zava-presenter-key": key}, cache: "no-store",
         signal: AbortSignal.timeout(10000)},
      );
      if (request !== pollRequest || key !== activePresenterKey) return;
      renderInjectionStatus(injection);
    } catch (err) {
      if (request !== pollRequest || key !== activePresenterKey) return;
      presenterInjection = null;
      updateVotingControls();
      injectionStatus.textContent = `Could not check the private runner - ${err.message}`;
      if (err.status === 403) {
        activePresenterKey = "";
        updateVotingControls();
      }
    }
  } catch (err) {
    if (request !== pollRequest) return;
    presenterPoll = null;
    pollReadFailed = true;
    updateVotingControls();
    showBanner(`Could not read voting status - ${err.message}`, "error");
  } finally {
    refreshingPoll = false;
  }
}

async function changeVoting(action) {
  if (changingPoll || !activePresenterKey || !presenterPoll) return;
  if (action === "lock" && presenterPoll.state !== "open") return;
  if (action === "open" && openVoting.disabled) return;
  if (action === "inject" && injectFault.disabled) return;
  const resetPrevious = action === "open" && needsPollReset();
  if (resetPrevious && !window.confirm(
    "Open fresh voting? This closes the previous poll record but does not repair or undo " +
    "its fault. Repair the previous fault before injecting another one.",
  )) return;
  const path = action === "open"
    ? "/api/presenter/polls"
    : `/api/presenter/polls/${presenterPoll.poll_id}/${action}`;
  changingPoll = true;
  ++pollRequest;
  if (action === "inject") injectionStatus.textContent = "Requesting the winning fault...";
  updateVotingControls();
  try {
    const headers = {"x-zava-presenter-key": activePresenterKey};
    if (resetPrevious) {
      const previous = await getJSON(`/api/presenter/polls/${presenterPoll.poll_id}/state`, {
        method: "POST",
        headers: {...headers, "content-type": "application/json"},
        body: JSON.stringify({state: "closed"}),
      });
      presenterInjection = null;
      renderPresenterPoll(previous);
    }
    const poll = await getJSON(path, {
      method: "POST",
      headers,
    });
    if (action === "inject") renderInjectionStatus(poll);
    else {
      presenterInjection = null;
      renderPresenterPoll(poll);
      if (action === "open") injectionStatus.textContent = "Fresh voting opened. No fault has been requested.";
    }
    clearBanner();
  } catch (err) {
    const operation = {open: "open voting", lock: "close voting", inject: "request fault injection"}[action];
    showBanner(`Could not ${operation} - ${err.message}`, "error");
  } finally {
    changingPoll = false;
    updateVotingControls();
  }
}

async function saveKey() {
  const key = presenterKey.value.trim();
  if (!key || changingPoll || savingPresenterKey) return;
  savingPresenterKey = true;
  activePresenterKey = "";
  presenterInjection = null;
  const request = ++pollRequest;
  const pollId = presenterPoll && presenterPoll.poll_id || 0;
  injectionStatus.textContent = "Verifying presenter key...";
  updateVotingControls();
  try {
    const injection = await getJSON(`/api/presenter/polls/${pollId}/injection`, {
      headers: {"x-zava-presenter-key": key}, cache: "no-store",
      signal: AbortSignal.timeout(10000),
    });
    if (request !== pollRequest || key !== presenterKey.value.trim()) return;
    localStorage.setItem(PRESENTER_KEY_STORAGE, key);
    hasStoredPresenterKey = true;
    activePresenterKey = key;
    if (pollId === (presenterPoll && presenterPoll.poll_id || 0)) {
      renderInjectionStatus(injection);
    }
    clearBanner();
  } catch (err) {
    if (request !== pollRequest) return;
    injectionStatus.textContent = `Presenter key was not saved - ${err.message}`;
    showBanner(`Could not verify and save presenter key - ${err.message}`, "error");
  } finally {
    savingPresenterKey = false;
    updateVotingControls();
    refreshPresenterPoll();
  }
}

presenterKey.addEventListener("input", () => {
  activePresenterKey = "";
  presenterInjection = null;
  ++pollRequest;
  injectionStatus.textContent = "Save your presenter key to check the private runner.";
  updateVotingControls();
});
savePresenterKey.addEventListener("click", saveKey);
forgetPresenterKey.addEventListener("click", () => {
  try {
    localStorage.removeItem(PRESENTER_KEY_STORAGE);
  } catch (err) {
    showBanner(`Could not forget presenter key - ${err.message}`, "error");
    return;
  }
  activePresenterKey = "";
  hasStoredPresenterKey = false;
  presenterKey.value = "";
  presenterInjection = null;
  ++pollRequest;
  injectionStatus.textContent = "Presenter key forgotten. Save a key to unlock the controls.";
  clearBanner();
  updateVotingControls();
});
openVoting.addEventListener("click", () => changeVoting("open"));
closeVoting.addEventListener("click", () => changeVoting("lock"));
injectFault.addEventListener("click", () => changeVoting("inject"));
releaseGolden.addEventListener("click", releaseGoldenShipment);
refreshPresenterPoll();
refreshGoldenShipment();
setInterval(() => {
  refreshPresenterPoll();
  refreshGoldenShipment();
}, window.REFRESH_MS || 3000);
try {
  const savedKey = localStorage.getItem(PRESENTER_KEY_STORAGE);
  if (savedKey) {
    hasStoredPresenterKey = true;
    presenterKey.value = savedKey;
    saveKey();
  }
} catch (err) {
  showBanner(`Could not read saved presenter key - ${err.message}`, "error");
}
