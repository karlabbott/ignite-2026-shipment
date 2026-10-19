/* Infrastructure commands run only on the private, outbound-polling runner. */

const presenterKey = document.getElementById("presenter-key");
const savePresenterKey = document.getElementById("save-presenter-key");
const forgetPresenterKey = document.getElementById("forget-presenter-key");
const openVoting = document.getElementById("open-voting");
const closeVoting = document.getElementById("close-voting");
const injectFault = document.getElementById("inject-fault");
const injectionStatus = document.getElementById("injection-status");
const injectionReason = document.getElementById("injection-disabled-reason");
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

function updateVotingControls() {
  const hasKey = Boolean(activePresenterKey);
  savePresenterKey.disabled = changingPoll || savingPresenterKey || !presenterKey.value.trim();
  forgetPresenterKey.disabled = changingPoll || savingPresenterKey ||
    (!presenterKey.value.trim() && !hasStoredPresenterKey);
  const state = presenterPoll && presenterPoll.state;
  const unresolved = presenterInjection &&
    ["queued", "running", "failed"].includes(presenterInjection.state) &&
    !["recovered", "closed"].includes(state);
  openVoting.disabled = changingPoll || !hasKey || !presenterPoll ||
    state === "open" || state === "injected" || unresolved;
  closeVoting.disabled = changingPoll || !hasKey || state !== "open";
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

function renderInjectionStatus(injection) {
  presenterInjection = injection;
  injectionStatus.textContent = {
    queued: "Fault requested. Waiting for the private runner.",
    running: injection.runner_online
      ? "Private runner is injecting the winning fault."
      : "Injection was claimed, but the runner is offline. Inspect its log; do not retry blindly.",
    succeeded: "Winning fault injected. Use the reviewed private repair after troubleshooting.",
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
    injected: "Fault active",
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
  if (action === "open" && ["open", "injected"].includes(presenterPoll.state)) return;
  if (action === "inject" && injectFault.disabled) return;
  const path = action === "open"
    ? "/api/presenter/polls"
    : `/api/presenter/polls/${presenterPoll.poll_id}/${action}`;
  changingPoll = true;
  ++pollRequest;
  if (action === "inject") injectionStatus.textContent = "Requesting the winning fault...";
  updateVotingControls();
  try {
    const poll = await getJSON(path, {
      method: "POST",
      headers: {"x-zava-presenter-key": activePresenterKey},
    });
    if (action === "inject") renderInjectionStatus(poll);
    else {
      presenterInjection = null;
      renderPresenterPoll(poll);
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
refreshPresenterPoll();
setInterval(refreshPresenterPoll, window.REFRESH_MS || 3000);
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
