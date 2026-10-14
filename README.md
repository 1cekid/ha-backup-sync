# Backup Sync for Home Assistant

A resumable backup sync that survives Home Assistant restarts.

- **Add-on** (`addons/backup_sync`): uploads the newest backup with rsync over SSH, resumes
  interrupted transfers, prunes old backups on the server, logs in detail and reports progress.
- **Custom integration** (`custom_components/backup_sync`): persistent sensors (status, progress,
  speed, ETA, last success, last error, ...) that keep their values across HA restarts. No MQTT needed.

The add-on talks to the integration with a custom event through the Supervisor proxy
(`POST /core/api/events/backup_sync_update`), so the only requirement is `homeassistant_api: true`.

## Installation

1. **Add-on:** copy `addons/backup_sync` to the `/addons` share of your HA host
   (Samba or SSH add-on). In *Settings > Add-ons > Add-on store*, use the menu > *Check for updates*,
   then install *Backup Sync* from *Local add-ons*.
2. **Integration:** copy `custom_components/backup_sync` to `/config/custom_components/`,
   restart Home Assistant, then *Settings > Devices & services > Add integration > Backup Sync*.
3. **Configure the add-on:** set `host`, `user`, `remote_path`, `keep_count`. Start it once:
   it generates an SSH key and prints the public key in the log. Add that key to
   `~/.ssh/authorized_keys` on the server (use a dedicated user that only owns the backup directory), then start it again.

## Dashboard card

```yaml
type: entities
title: Backup Sync
entities:
  - sensor.backup_sync_status
  - sensor.backup_sync_progress
  - sensor.backup_sync_speed
  - sensor.backup_sync_eta
  - sensor.backup_sync_file
  - sensor.backup_sync_last_success
  - sensor.backup_sync_backups_on_server
  - sensor.backup_sync_last_error
```

## Things worth knowing

- **Resume:** partial uploads live as `<name>.part` on the server. After a resume the status is
  *Verifying existing data* until the existing part has been checksummed on both ends (minutes for
  tens of GB), then the transfer continues.
- **No delta sync:** HA backups are compressed (and possibly encrypted), so rsync cannot reuse blocks
  of yesterday's file. Every day's backup is transferred in full; rsync is used for resume and retries.
- **Disk space on the server:** plan for `keep_count + 1` backups.
- **Host reboot:** a reboot stops the add-on. The *Home Assistant start* trigger in the first automation
  starts it again and the upload resumes.
- **Stale detection:** if the add-on dies without a goodbye, the status sensor switches to
  *No signal from add-on* after about 2.5 minutes without a heartbeat.
- **Recorder:** progress sensors change every few seconds during uploads. Exclude them from the
  recorder if you do not want the history.
- **Remote shell:** all remote commands run through `sh -c`, so the login shell does not matter.
  The server needs `rsync` installed.