"""Validate every machine-readable answer file in estate/.

These files are consumed by installers that fail late, slowly and unhelpfully --
a bad kickstart wastes a VM boot, a bad Agama profile drops you to a shell, and
a malformed cloud-config is silently ignored until you notice the user account
was never created. Catching syntax errors here costs a second instead of ten
minutes.

Placeholders (!!SSH_PUBKEY!! etc.) are substituted with dummies first, because
the committed files are templates -- build-answer-isos.sh renders the real ones.

Run:  .venv\\Scripts\\python.exe tools\\validate-answer-files.py
"""

import json
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("pyyaml required:  .venv\\Scripts\\pip.exe install pyyaml")

ROOT = Path(__file__).resolve().parent.parent
ESTATE = ROOT / "estate"

PLACEHOLDERS = {
    "!!SSH_PUBKEY!!": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIdummy estate@lab",
    "!!PASSWORD_HASH!!": "$6$rounds=4096$dummy$dummydummydummy",
    "!!SCC_REGISTRATION!!": "",
    "!!CIQ_REG_CODE!!": "DUMMY-CIQ-CODE",
    "!!RHSM_ORGANIZATION!!": "1234567",
    "!!RHSM_ACTIVATION_KEY!!": "dummy-activation-key",
    "!!DNS_SERVERS!!": "1.1.1.1,8.8.8.8",
    "!!DNS_SERVERS_JSON!!": '"1.1.1.1", "8.8.8.8"',
}

failures = []
checked = 0


def render(path):
    text = path.read_text(encoding="utf-8")
    for token, value in PLACEHOLDERS.items():
        text = text.replace(token, value)
    if path.suffix == ".ks":
        # Match build-answer-isos.sh: RHEL 10's parser rejects a literal
        # shell-style continuation backslash in a Kickstart directive.
        rendered = []
        lines = text.splitlines()
        index = 0
        while index < len(lines):
            line = lines[index]
            if line.startswith(("network ", "user ", "bootloader ")):
                directive = line.rstrip().rstrip("\\").rstrip()
                while index + 1 < len(lines) and lines[index + 1].lstrip().startswith("--"):
                    index += 1
                    directive += " " + lines[index].strip().rstrip("\\").rstrip()
                rendered.append(directive)
            else:
                rendered.append(line)
            index += 1
        text = "\n".join(rendered) + "\n"
    return text


def report(path, ok, detail=""):
    global checked
    checked += 1
    rel = path.relative_to(ROOT).as_posix()
    if ok:
        print(f"  [ok  ] {rel}{'  ' + detail if detail else ''}")
    else:
        print(f"  [FAIL] {rel}\n         {detail}")
        failures.append(rel)


def check_yaml(path, expect_keys=(), cloud_config=False):
    try:
        text = render(path)
        if cloud_config and not text.lstrip().startswith("#cloud-config"):
            report(path, False, "cloud-init ignores this file without a #cloud-config first line")
            return
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        report(path, False, str(exc).replace("\n", "\n         "))
        return
    if data is None:
        report(path, False, "parsed as empty")
        return
    missing = [k for k in expect_keys if k not in data]
    if missing:
        report(path, False, f"missing expected key(s): {', '.join(missing)}")
        return
    report(path, True, f"{len(data)} top-level keys" if isinstance(data, dict) else "")


def check_json(path, expect_keys=()):
    try:
        data = json.loads(render(path))
    except json.JSONDecodeError as exc:
        report(path, False, f"line {exc.lineno} col {exc.colno}: {exc.msg}")
        return
    missing = [k for k in expect_keys if k not in data]
    if missing:
        report(path, False, f"missing expected key(s): {', '.join(missing)}")
        return
    report(path, True, f"{len(data)} top-level keys")


def check_kickstart(path):
    """Anaconda has no dry-run, so assert the structural invariants by hand."""
    text = render(path)
    lines = text.splitlines()
    problems = []

    if "\r" in text:
        problems.append("contains CRLF; Anaconda will fail to parse it")

    for section in ("%packages", "%post"):
        opens = sum(1 for ln in lines if ln.strip().startswith(section))
        if opens == 0:
            problems.append(f"no {section} section")

    # Every %section must be closed by %end or Anaconda halts on a syntax error.
    open_sections = 0
    for ln in lines:
        s = ln.strip()
        if s.startswith("%") and not s.startswith("%end") and not s.startswith("%%"):
            if s.split()[0] in ("%packages", "%post", "%pre", "%addon", "%anaconda"):
                open_sections += 1
        elif s.startswith("%end"):
            open_sections -= 1
    if open_sections != 0:
        problems.append(f"unbalanced %section/%end (delta {open_sections})")

    if not any(ln.strip().startswith(("rootpw", "user ")) for ln in lines):
        problems.append("no rootpw or user directive; install will prompt and hang")

    if re.search(r"--\*+", text):
        problems.append("contains a redacted option instead of a real Kickstart directive")

    if any(ln.strip() == "rootpw --lock" for ln in lines):
        user_lines = [ln for ln in lines if ln.startswith("user ")]
        if user_lines and not any("--password=" in ln for ln in user_lines):
            problems.append("root is locked but the user directive has no console password")

    # Anaconda accepts a syntactically valid `network --bootproto=static` line
    # without --ip, then crashes during NetworkManager setup with
    # "Invalid IPv4 address ''". Treat this as a template error, not a guest
    # runtime surprise.
    for number, line in enumerate(lines, start=1):
        if line.startswith("network ") and "--bootproto=static" in line and "--ip=" not in line:
            problems.append(f"line {number}: static network directive has no --ip")

    leftover = [t for t in PLACEHOLDERS if t in path.read_text(encoding="utf-8")]
    detail = f"{len(lines)} lines"
    if leftover:
        detail += f", templated: {', '.join(leftover)}"

    report(path, not problems, "; ".join(problems) or detail)


print("\nKickstart (RHEL / RLC+)")
for ks in sorted((ESTATE / "kickstart").glob("*.ks")):
    check_kickstart(ks)

print("\nAgama (SLES 16)")
for js in sorted((ESTATE / "agama").glob("*.json")):
    check_json(js, expect_keys=("product", "user"))

print("\nsubiquity autoinstall (Ubuntu 26.04)")
ai = ESTATE / "autoinstall"
if (ai / "user-data").exists():
    check_yaml(ai / "user-data", expect_keys=("autoinstall",))
if (ai / "meta-data").exists():
    check_yaml(ai / "meta-data")

print()
if failures:
    print(f"FAILED: {len(failures)} of {checked} file(s): {', '.join(failures)}")
    sys.exit(1)
print(f"All {checked} answer files valid.")
