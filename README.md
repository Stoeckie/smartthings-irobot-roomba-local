# iRobot Roomba (local): SmartThings Edge driver

Status and control of an **iRobot Roomba** in SmartThings, directly from the hub over the robot's own local MQTT connection (TLS, port 8883). No cloud, no bridge computer, no IFTTT.

## What you get

* `robotCleanerMovement`: cleaning, pause, homing, charging, idle, alarm (stuck or error). Set it to start, pause, stop or send the robot home
* `switch`: on = start (or resume a paused job), off = back to the dock
* `battery`
* **Favorite** (custom capability `silvervalley08660.robotFavorites`, on the main card): a list with your iRobot app favorites (room cleaning), plus Whole home and Idle. Pick one to start it. Also usable in routines (condition and action)
* **Empty bin** button in the same card: empties the bin into the Clean Base (models with auto empty)

Since build 2026-11-08a the separate Favorites and Empty bin components are gone; routines that used them must be set up again with **Favorite** / **Start favorite**. Since build 2026-11-08d Connection status and Last drop are in their own **Connection** card at the bottom; an existing offline routine must pick the Connection status again from that card.
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

The iRobot app keeps favorites in the cloud. Two ways to get them into the **Favorite** list:

**Automatic, with a Stoeckie Bridge** ([smartthings-stoeckie-bridge](https://github.com/Stoeckie/smartthings-stoeckie-bridge)): enter your iRobot login on the bridge setup page. The driver finds the bridge on the network (setting **Stoeckie Bridge IP**: `auto`, a fixed IP or `off`) and shows your favorites with their names, refreshed every 6 hours and when you press Refresh. The robot is still controlled locally.

**Without a bridge**, the driver **learns** a favorite the first time it runs: start each favorite once from the iRobot app (or let a schedule run it). The driver stores the map and rooms on the hub and adds it to the Favorite list as "Favorite 1", "Favorite 2" and so on.

Name them in the device settings under **Favorite names**, comma separated in the order they were learned, e.g. `Kamer, Hele keuken`. The log shows `learned favorite N` each time. **Forget learned favorites** clears the list.

If you edit the map in the iRobot app, the driver sends the current map version; when rooms were renumbered, forget and learn the favorites again.

## Settings

| Setting | Meaning |
|---|---|
| Robot IP | `auto` (discovery) or a fixed IP |
| Robot password | Leave empty: the hub fetches it. Only paste one when you already have it from another tool (roombapy, dorita980) |
| Forget password | Forget the stored password, then hold HOME again |
| Stoeckie Bridge IP | `auto`, a fixed IP or `off`: favorites with names from the iRobot account via the bridge |
| Favorite names | Names for the learned favorites (without a bridge), comma separated |
| Forget learned favorites | Clear the learned favorites |

## Offline notification

SmartThings has no routine trigger for "device offline". The Roomba device therefore has a **Connection** card at the bottom of the device page (status Connected or Offline, plus the last drop). Make a routine to get a message:

If Roomba device > Connection is Offline, then send a notification to members.

For a "back online" message as well, duplicate that routine and change the condition to Connection is Connected (e.g. text "... is back online"). Then you know the problem is over without opening the app.

Short drops (a reconnect or one missed poll) are ignored: Connection only turns Offline after 2 minutes without a connection.

Every drop is remembered. When the connection is back, the device shows **Last drop**: time (UTC), how long it lasted and the reason (for example "session closed" or "timeout"). Older drops are in the device history.

## Certificate pinning

The robot uses a self-signed certificate, so it cannot be checked against a certificate authority. The driver remembers the robot's certificate (a hash of the certificate; SmartThings hubs cannot give the usual fingerprint) at the first connection that carries the password. When another certificate answers later (another device on that address, or someone in between), the driver refuses and does not send the password; the log says so. Replaced the robot? Enter the password again: the next certificate is then trusted. On a hub that cannot read certificates the driver logs that pinning is off and works as before.

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
