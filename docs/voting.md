# Audience voting

- Presenter controls: `https://dash.99b.org/voting`.
- Audience voting: `https://track.99b.org/vote`.
- Projected voting screen: `https://dash.99b.org/?view=network`.

Enter the existing presenter key in the control page. It is kept only in the
page's password field, never in browser storage, URLs, or deployed source.
Reloading the page requires entering it again.

**Open voting** creates a poll. **Close voting** locks it and reveals the winner;
neither action injects a fault. Fault injection remains a separate private
operation. Opening another poll creates a fresh vote, not a continuation of the
previous tally. Open voting is disabled while a poll is open or a fault is active.

While voting is open, the projected screen shows a locally served QR code and
readable voting URL, and the tracking page shows a **Vote now** link. Vote counts
per choice remain hidden until voting locks.

The tracking page's **Clear history** button removes only this browser's saved
shipment list. It does not delete SQL shipments or reset the browser's voter token.

The voting UI must be deployed before refreshing the web baseline snapshot.
Snapshot capture is a separate operation, not part of a UI deployment.

Focused UI regressions: `python tools/test-voting-ui.py`. Test-only dependencies
are `playwright`, `zxing-cpp`, and `Pillow`, plus the existing Jinja2 dependency.
The tests use installed Edge on Windows; on Linux run
`python -m playwright install chromium` first. All API mutations are mocked.
