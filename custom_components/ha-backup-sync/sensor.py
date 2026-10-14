"""Sensors for the Backup Sync integration.

The add-on fires a ``backup_sync_update`` event (state + progress). The sensors
listen for it and restore their last value after a Home Assistant restart, so the
information survives restarts of Core even though the add-on keeps running.
"""
from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from homeassistant.components.sensor import (
    RestoreSensor,
    SensorDeviceClass,
    SensorEntityDescription,
)
from homeassistant.config_entries import ConfigEntry
from homeassistant.const import PERCENTAGE, UnitOfDataRate, UnitOfInformation
from homeassistant.core import Event, HomeAssistant, callback
from homeassistant.helpers.device_registry import DeviceInfo
from homeassistant.helpers.entity_platform import AddEntitiesCallback
from homeassistant.helpers.event import async_track_time_interval
from homeassistant.util import dt as dt_util

from .const import ACTIVE_STATUSES, ADDON_STATUSES, DOMAIN, EVENT_UPDATE, STALE_AFTER, STATUSES

# Returned by a value function when the event carries nothing usable for the sensor
UNCHANGED: Any = object()

ValueFn = Callable[[Mapping[str, Any], datetime], Any]


def _as_int(data: Mapping[str, Any], key: str) -> int | None:
    try:
        return int(data[key])
    except (KeyError, TypeError, ValueError):
        return None


def _status(data: Mapping[str, Any], _fired: datetime) -> Any:
    value = data.get("status")
    return value if value in ADDON_STATUSES else UNCHANGED


def _progress(data: Mapping[str, Any], _fired: datetime) -> Any:
    done = _as_int(data, "bytes_done")
    total = _as_int(data, "bytes_total")
    if done is None or not total or total <= 0:
        return UNCHANGED
    return round(min(done / total * 100, 100), 1)


def _bytes(key: str) -> ValueFn:
    def fn(data: Mapping[str, Any], _fired: datetime) -> Any:
        value = _as_int(data, key)
        return UNCHANGED if value is None or value < 0 else value

    return fn


def _speed(data: Mapping[str, Any], _fired: datetime) -> Any:
    if data.get("status") != "uploading":
        return 0
    value = _as_int(data, "speed")
    return UNCHANGED if value is None or value < 0 else value


def _eta(data: Mapping[str, Any], fired: datetime) -> Any:
    seconds = _as_int(data, "eta_seconds")
    if data.get("status") != "uploading" or not seconds or seconds <= 0:
        return None
    # truncated to the minute so the state does not change on every update
    return (fired + timedelta(seconds=seconds)).replace(second=0, microsecond=0)


def _text(key: str) -> ValueFn:
    def fn(data: Mapping[str, Any], _fired: datetime) -> Any:
        value = data.get(key)
        if value is None:
            return UNCHANGED
        value = str(value).strip()
        # entity states are limited to 255 characters
        return value[:255] if value else None

    return fn


def _last_success(data: Mapping[str, Any], _fired: datetime) -> Any:
    timestamp = _as_int(data, "last_success_ts")
    if not timestamp or timestamp <= 0:
        return UNCHANGED
    return dt_util.utc_from_timestamp(timestamp)


@dataclass(frozen=True, kw_only=True)
class BackupSyncSensorDescription(SensorEntityDescription):
    """Sensor description with a function that extracts the value from an event."""

    value_fn: ValueFn


DESCRIPTIONS: tuple[BackupSyncSensorDescription, ...] = (
    BackupSyncSensorDescription(
        key="status",
        translation_key="status",
        device_class=SensorDeviceClass.ENUM,
        options=STATUSES,
        value_fn=_status,
    ),
    BackupSyncSensorDescription(
        key="progress",
        translation_key="progress",
        native_unit_of_measurement=PERCENTAGE,
        suggested_display_precision=1,
        value_fn=_progress,
    ),
    BackupSyncSensorDescription(
        key="bytes_done",
        translation_key="bytes_done",
        device_class=SensorDeviceClass.DATA_SIZE,
        native_unit_of_measurement=UnitOfInformation.BYTES,
        suggested_unit_of_measurement=UnitOfInformation.GIGABYTES,
        suggested_display_precision=1,
        value_fn=_bytes("bytes_done"),
    ),
    BackupSyncSensorDescription(
        key="bytes_total",
        translation_key="bytes_total",
        device_class=SensorDeviceClass.DATA_SIZE,
        native_unit_of_measurement=UnitOfInformation.BYTES,
        suggested_unit_of_measurement=UnitOfInformation.GIGABYTES,
        suggested_display_precision=1,
        value_fn=_bytes("bytes_total"),
    ),
    BackupSyncSensorDescription(
        key="speed",
        translation_key="speed",
        device_class=SensorDeviceClass.DATA_RATE,
        native_unit_of_measurement=UnitOfDataRate.BYTES_PER_SECOND,
        suggested_unit_of_measurement=UnitOfDataRate.MEGABYTES_PER_SECOND,
        suggested_display_precision=1,
        value_fn=_speed,
    ),
    BackupSyncSensorDescription(
        key="eta",
        translation_key="eta",
        device_class=SensorDeviceClass.TIMESTAMP,
        value_fn=_eta,
    ),
    BackupSyncSensorDescription(
        key="current_file",
        translation_key="current_file",
        value_fn=_text("file"),
    ),
    BackupSyncSensorDescription(
        key="last_success",
        translation_key="last_success",
        device_class=SensorDeviceClass.TIMESTAMP,
        value_fn=_last_success,
    ),
    BackupSyncSensorDescription(
        key="last_error",
        translation_key="last_error",
        value_fn=_text("last_error"),
    ),
    BackupSyncSensorDescription(
        key="remote_backups",
        translation_key="remote_backups",
        value_fn=lambda data, _fired: (
            UNCHANGED
            if (count := _as_int(data, "remote_count")) is None or count < 0
            else count
        ),
    ),
)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddEntitiesCallback,
) -> None:
    """Create the sensors."""
    async_add_entities(
        (
            BackupSyncStatusSensor if description.key == "status" else BackupSyncSensor
        )(entry, description)
        for description in DESCRIPTIONS
    )


class BackupSyncSensor(RestoreSensor):
    """A sensor that is updated by events from the add-on and restored on restart."""

    entity_description: BackupSyncSensorDescription
    _attr_has_entity_name = True
    _attr_should_poll = False

    def __init__(
        self, entry: ConfigEntry, description: BackupSyncSensorDescription
    ) -> None:
        self.entity_description = description
        self._attr_unique_id = f"{entry.entry_id}_{description.key}"
        self._attr_device_info = DeviceInfo(
            identifiers={(DOMAIN, entry.entry_id)},
            name="Backup Sync",
            manufacturer="Local add-on",
            model="Backup Sync",
        )
        self._attr_native_value = None

    async def async_added_to_hass(self) -> None:
        """Restore the last value and start listening for events."""
        await super().async_added_to_hass()
        if (last := await self.async_get_last_sensor_data()) is not None:
            self._attr_native_value = last.native_value
        self.async_on_remove(
            self.hass.bus.async_listen(EVENT_UPDATE, self._handle_event)
        )

    @callback
    def _handle_event(self, event: Event) -> None:
        value = self.entity_description.value_fn(event.data, event.time_fired)
        if value is UNCHANGED:
            return
        self._attr_native_value = value
        self.async_write_ha_state()


class BackupSyncStatusSensor(BackupSyncSensor):
    """Status sensor that also detects a silent (crashed or stopped) add-on."""

    _last_seen: datetime

    async def async_added_to_hass(self) -> None:
        """Start the stale check; the grace period starts now."""
        await super().async_added_to_hass()
        self._last_seen = dt_util.utcnow()
        self.async_on_remove(
            async_track_time_interval(
                self.hass, self._check_stale, timedelta(seconds=30)
            )
        )

    @callback
    def _handle_event(self, event: Event) -> None:
        self._last_seen = dt_util.utcnow()
        super()._handle_event(event)

    @callback
    def _check_stale(self, _now: datetime) -> None:
        if (
            self._attr_native_value in ACTIVE_STATUSES
            and dt_util.utcnow() - self._last_seen > STALE_AFTER
        ):
            self._attr_native_value = "stale"
            self.async_write_ha_state()
