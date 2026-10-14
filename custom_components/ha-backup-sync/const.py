"""Constants for the Backup Sync integration."""
from __future__ import annotations

from datetime import timedelta

DOMAIN = "backup_sync"

# Event fired by the add-on through the Supervisor proxy (POST /core/api/events/<type>)
EVENT_UPDATE = "backup_sync_update"

# Statuses the add-on can report
ADDON_STATUSES = [
    "idle",
    "starting",
    "verifying",
    "uploading",
    "retrying",
    "pruning",
    "error",
    "interrupted",
]
# "stale" is set by the integration if the add-on stops sending heartbeats
STATUSES = [*ADDON_STATUSES, "stale"]

# While the add-on is in one of these states it is expected to send heartbeats
ACTIVE_STATUSES = {"starting", "verifying", "uploading", "retrying", "pruning"}

# The add-on sends a heartbeat every 30 s; this is the grace period before "stale"
STALE_AFTER = timedelta(seconds=150)
