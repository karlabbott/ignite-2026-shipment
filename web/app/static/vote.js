/* Audience voting client. One browser token may change its vote while open. */

const choices = document.getElementById("vote-choices");
const statusLine = document.getElementById("vote-status");
let currentPoll = null;

function voterToken() {
  const key = "zava-failure-voter";
  let token = localStorage.getItem(key);
  if (!token) {
    const bytes = new Uint8Array(24);
    crypto.getRandomValues(bytes);
    token = Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
    localStorage.setItem(key, token);
  }
  return token;
}

function choiceMarkup(choice, total, state, winner) {
  const open = state === "open";
  const percent = total ? Math.round((choice.votes / total) * 100) : 0;
  const selected = localStorage.getItem(`zava-failure-vote:${currentPoll.poll_id}`) === choice.code;
  const won = winner === choice.code;
  return `
    <button class="vote-choice${selected ? " selected" : ""}${won ? " winner" : ""}"
            type="button" data-choice="${escapeHTML(choice.code)}"
            ${state === "open" ? "" : "disabled"}>
      <span class="vote-choice-heading">
        <strong>${escapeHTML(choice.label)}</strong>
        ${open ? `<b class="vote-selection">${selected ? "Selected" : "Choose"}</b>` : `<b>${choice.votes}</b>`}
      </span>
      ${open ? "" : `
        <span class="vote-bar"><i style="width:${percent}%"></i></span>
        <span class="vote-percent">${percent}%${won ? " · selected by the room" : ""}</span>`}
    </button>`;
}

function render(poll) {
  currentPoll = poll;
  if (!poll.poll_id) {
    choices.innerHTML = "";
    statusLine.textContent = "Waiting for the poll to open.";
    return;
  }
  choices.innerHTML = poll.choices.map(
    (choice) => choiceMarkup(choice, poll.total_votes, poll.state, poll.winner_code),
  ).join("");
  if (poll.state === "open") {
    statusLine.textContent = `${poll.total_votes} vote${poll.total_votes === 1 ? "" : "s"} received · Results remain hidden until voting locks.`;
  } else if (poll.winner_code) {
    const winner = poll.choices.find((choice) => choice.code === poll.winner_code);
    statusLine.textContent = `Voting locked: ${winner ? winner.label : "winner selected"}.`;
  } else {
    statusLine.textContent = "Voting is closed.";
  }
}

async function refresh() {
  try {
    render(await getJSON("/api/poll"));
    clearBanner();
  } catch (err) {
    showBanner(`Poll unavailable — ${err.message}`, "error");
  }
}

choices.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-choice]");
  if (!button || !currentPoll || currentPoll.state !== "open") return;
  button.disabled = true;
  try {
    const poll = await getJSON("/api/poll/vote", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        poll_id: currentPoll.poll_id,
        voter_token: voterToken(),
        choice_code: button.dataset.choice,
      }),
    });
    localStorage.setItem(`zava-failure-vote:${poll.poll_id}`, button.dataset.choice);
    render(poll);
  } catch (err) {
    showBanner(`Vote not recorded — ${err.message}`, "error");
    button.disabled = false;
  }
});

refresh();
setInterval(refresh, window.REFRESH_MS || 3000);
