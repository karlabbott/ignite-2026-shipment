# Seattle to Paris teaser

A 24-second, 1080-square, 30 fps H.264 MP4 for sound-off LinkedIn viewing.
The golden package travels across the five existing distro logos. All text is
burned in; no music, voice recording, external asset service, or live estate
dependency is used. This is a promotional animation, not recorded telemetry.

Render on Windows with Python, Pillow, Playwright, installed Edge, and ffmpeg:

```powershell
python .\marketing\render-teaser.py
```

Produces `ignite-teaser-v1.mp4`, a PNG end card, and a six-frame storyboard.
Reuse the existing distro assets from `web\app\static\logos`; respective names
and logos remain their owners' trademarks. The default fonts are local Segoe UI;
other systems can supply `--font` and `--regular-font` and installed Chromium.

Beats: Seattle-to-Paris hook; five distros/one application; datacenter-to-Azure;
audience chooses the incident; live-recovery question; Ignite end card.
No session date, official session title, or promotional-site URL is invented.
