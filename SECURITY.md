# Security Policy

## What VenzAI does with your data

VenzAI is a Lightroom Classic plug-in. Its security guarantees are worth
stating plainly, because a plug-in that sends photographs to cloud services
is one where the guarantees matter.

- **API keys** are stored in the operating system keychain (macOS Keychain,
  Windows Credential Manager). They are never written to a preferences file
  or to disk in plain text.
- **The exported JPEG** is stripped of all metadata segments before upload —
  no camera serial, GPS, face tags, or XMP block. What is removed is named
  in the log. If the strip fails, the run stops rather than uploading a file
  whose contents are unknown.
- **Nothing else is sent.** VenzAI contacts only the provider you configured.
  It has no analytics, no telemetry, and no server of its own.
- **With Ollama, nothing leaves the machine at all.**

## Supported versions

Only the latest release is supported. If you are running an older version,
update before reporting.

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

Use GitHub's private vulnerability reporting:
**Security → Report a vulnerability** on this repository's page.

Include:

- A description of the vulnerability and what it allows.
- The steps or conditions needed to trigger it.
- The build number from the first line of `VenzAI.log`.

You will receive a response within a week. If the vulnerability is confirmed,
a fix will be published as soon as possible and credited to you unless you
ask otherwise.
