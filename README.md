# iRobot Roomba (local): SmartThings Edge driver

Status and control of an **iRobot Roomba** in SmartThings, directly from the hub over the robot's own local MQTT connection (TLS, port 8883). No cloud, no bridge computer, no IFTTT.

## What you get

* `robotCleanerMovement`: cleaning, pause, homing, charging, idle, alarm (stuck or error). Set it to start, pause, stop or send the robot home
* `switch`: on = start (or resume a paused job), off = back to the dock
* `battery`
* Component **Favorites** (`mode`): your iRobot app favorites (room cleaning), plus Whole home and Idle. Pick one to start it
* Component **Empty bin** (`momentary`): empties the bin into the Clean Base (models with auto empty)
* Live updates: the robot pushes every change
* Routine examples: *movement changes to charging → "Roomba is done"*, *movement is alarm → "Roomba is stuck"*, *everyone left → switch on*

## Which robots

Roombas with wifi that run the local MQTT broker: 600 and 900 series with wifi, i3, i7, i8, s9, j7 and similar. Tested with a **Roomba s9+** (firmware 22.29.10).

The 2025 models (Roomba 105, 205, 405, 505 and others) refuse local connections. The Combo 10 Max, Plus 500 Combo and Max 700 have **Matter** instead: pair them in SmartThings as a Matter device, no driver needed.

## Install

1. Enroll your hub in the channel: https://bestow-regional.api.smartthings.com/invite/qWjBdybRNG2y (Stoeckie Edge Drivers) and install **iRobot Roomba (local)**.
2. SmartThings app: **Add device → Scan nearby**. Your robot appears with its iRobot name (found with the iRobot discovery broadcast on UDP 5678).
3. Put the robot on its dock and **hold HOME for 2 seconds** until it plays tones. The hub fetches the robot password and stores it. It keeps trying every few seconds until you do this, so there is no hurry.
4. The device goes online and shows the state.

Give the robot a fixed IP (DHCP reservation). If it is not found, set the IP in the device settings.

The robot accepts **one local connection at a time**. If Home Assistant or another local tool is connected, disconnect it first. The iRobot app keeps working (it uses the cloud).

## Favorites

The iRobot app keeps favorites in the cloud; locally the robot only reports the last command. So the driver **learns** a favorite the first time it runs: start each favorite once from the iRobot app (or let a schedule run it). The driver stores the map and rooms on the hub and adds it to the Favorites list as "Favorite 1", "Favorite 2" and so on.

Name them in the device settings under **Favorite names**, comma separated in the order they were learned, e.g. `Kamer, Hele keuken`. The log shows `learned favorite N` each time. **Forget learned favorites** clears the list.

If you edit the map in the iRobot app, the driver sends the current map version; when rooms were renumbered, forget and learn the favorites again.

## Settings

| Setting | Meaning |
|---|---|
| Robot IP | `auto` (discovery) or a fixed IP |
| Robot password | Leave empty: the hub fetches it. Only paste one when you already have it from another tool (roombapy, dorita980) |
| Forget password | Forget the stored password, then hold HOME again |
| Favorite names | Names for the learned favorites, comma separated |
| Forget learned favorites | Clear the learned favorites |

## Privacy

The robot password is stored on the hub only (persistent device field) or in the device setting. Nothing secret is in this code or the package. The driver never logs the password.

## How it works

* Discovery: UDP `irobotmcs` to port 5678 (broadcast and every host of the hub's /24); the robot answers with its name, model and BLID.
* Password: TLS to port 8883, request `f0 05 ef cc 3b 29 00`; the robot answers with its password only while HOME was just held.
* State: MQTT 3.1.1 login with BLID and password, subscribe `#`, merge the shadow updates (`state.reported`): `cleanMissionStatus` (cycle, phase, error), `batPct`, `bin`.
* Commands: `{"command": "start|pause|resume|stop|dock|evac", "time": ..., "initiator": "localApp"}` on topic `cmd`. Off while cleaning sends pause first, then dock.
* Favorites: learned from `lastCommand` (`pmap_id`, `regions`, `ordered`), started with `start` plus those fields and the current `user_pmapv_id` from `pmaps`.
* TLS verification is off: the robot uses a self-signed certificate (LAN only).

Protocol details from [roombapy](https://github.com/pschmitt/roombapy) and [dorita980](https://github.com/koalazak/dorita980).

## Development

```
smartthings edge:drivers:package .
pip install lupa pytest && python -m pytest tests
```

The tests run the driver with a mocked SmartThings runtime against a fake Roomba (password fetch, MQTT login, state, commands, a wrong password).

## License

Apache 2.0, see LICENSE. Not affiliated with iRobot or Samsung SmartThings.
