# Nginx Error Log Summary

Turn a noisy Nginx error log into a one-page report: which errors are happening, how often, and where.

## What it reports

- **Total entries** (optionally filtered with `--since YYYY-MM-DD`).
- **Counts by severity** — emerg, alert, crit, error, warn, notice, info, debug.
- **Top error messages** — per-request details (client IP, server, request line, upstream, host, referrer) are stripped before counting, so the same problem groups together instead of appearing once per visitor.
- **Top PHP fatal-error files** — which scripts are actually crashing, ranked by occurrence.
- **Upstream timeouts and SSL errors** — quick counts for the two problems that usually mean "the backend or the certificate is broken".

## Usage

```bash
# Defaults: /var/log/nginx/error.log, top 10
./log-summary.sh

# Only this week's entries, top 20
./log-summary.sh --file /var/log/nginx/error.log --since 2026-11-08 --top 20

# Machine-readable output for monitoring / CI
./log-summary.sh --json
```

Exit code `0` when entries were found, `2` when the log (or the `--since` window) has no matching entries, `1` on usage errors or an unreadable file.

## Example output

```
Nginx error log: /var/log/nginx/error.log
Total entries: 148

By severity:
  error    132
  warn     16

Top 10 messages:
      74  open() "/var/www/html/favicon.ico" failed (2: No such file or directory)
      31  connect() failed (111: Connection refused) while connecting to upstream
      12  FastCGI sent in stderr: "PHP message: PHP Fatal error:  Allowed memory size exhausted in /var/www/html/wp-includes/plugin.php on line 452"

Top PHP fatal-error files:
      12  /var/www/html/wp-includes/plugin.php

Upstream timeouts: 3
SSL errors:        0
```

## Requirements

Bash + `awk` + `sort` (standard on any Linux server). No root needed — just read access to the log file.
