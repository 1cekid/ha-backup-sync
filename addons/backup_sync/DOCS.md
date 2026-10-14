# Backup Sync

Uploads the newest Home Assistant backup from `/backup` to a remote server with
rsync over SSH. The upload is resumable, old backups on the server are pruned by the
add-on, and progress is reported to the `backup_sync` custom integration.

The add-on is meant to be **stopped by default**. It can be started by an automation after the
local backup has finished; it exits by itself when done.

## First start

1. Fill in `host`, `user` and `remote_path`, then start the add-on.
2. On the first start it generates an SSH key in its config folder
   (`/addon_configs/local_backup_sync/id_ed25519`) and prints the public key in the log.
3. Append that public key to `~/.ssh/authorized_keys` of the server user, start again.

The server's host key is stored on first connect (`known_hosts` in the same folder).
If it ever changes, the connection is refused until you remove the old entry.

## Options

| Option | Meaning |
| --- | --- |
| `host`, `port`, `user` | SSH target. Key authentication only. |
| `remote_path` | Directory on the server (absolute, or relative to the login directory). Created if missing. |
| `keep_count` | Number of finished backups to keep on the server. Older ones are deleted after a successful upload. |
| `file_pattern` | Glob for backup files, for example `*.tar`. Also used on the server, so only matching files are ever deleted. |
| `only_newest` | `true`: only the newest local backup is considered. `false`: all local backups missing on the server are uploaded (oldest first). |
| `stable_seconds` | The local file must keep its size for this long before the upload starts (guards against half-written backups). `0` disables the check. |
| `max_attempts`, `retry_delay` | How often and how fast failed steps are retried. rsync resumes where it stopped. |
| `bandwidth_limit_kbps` | Upload limit in KiB/s, `0` = unlimited. |
| `report_to_homeassistant` | Send status events to the integration. |
| `report_interval` | Seconds between progress updates sent to Home Assistant. |
| `log_level` | `trace`, `debug`, `info`, `notice`, `warning`, `error`, `fatal`. |

## How it works

- Files are uploaded as `<name>.part` and renamed once rsync has finished and the size matches,
  so a partial file is never mistaken for a complete backup.
- An interrupted upload continues with `--append-verify`: the existing part is checksummed on both
  ends first (status *Verifying existing data*, can take minutes for large files), then only the rest is sent.
- Retention runs only after a successful upload, never deletes a file uploaded in the same run,
  and is skipped if the server listing looks wrong.
- Free space on the server is checked before uploading (warning only). You need room for
  `keep_count + 1` backups, because the new file arrives before old ones are removed.

## Logging

`info` shows start/finish, retries, file sizes, durations and retention decisions, plus a progress line
every 10 minutes. `debug` adds the rsync command line and progress every `report_interval` seconds.
`trace` also logs every state event sent to Home Assistant.
