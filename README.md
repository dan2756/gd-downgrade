# GD Downgrade

Puts Steam Geometry Dash back on **2.2081**, and fixes **Geode and your mods** to match, so everything loads again after a GD update breaks it.

Updating GD to 2.2091 means updating Geode to v6 and moving your mods onto their 2.2091 builds. Mods that only exist for 2.2081 can't follow. If you then go back to 2.2081, Geode v6 and those 2.2091 mods all fail to load. GD Downgrade handles both halves: it downgrades the game, then puts Geode and every mod back on a 2.2081 build.

Windows + Steam only.

## How to use

1. Download **`GD-Downgrade.zip`** from the [latest release](https://github.com/dan2756/gd-downgrade/releases/latest).
2. Right-click the zip → **Extract All**, and open the extracted **GD Downgrade** folder.
3. Make sure Steam is open and Geometry Dash is closed.
4. Double-click **`Downgrade GD to 2.2081.bat`**.
5. When Steam's console opens, click the box at the bottom, press **Ctrl+V**, then **Enter**.
6. Wait for the window to say **Done**, then open GD from Steam like normal.

Windows may warn you before it runs a downloaded file. Click **Run**, or **More info** → **Run anyway**.

Already on 2.2081? Downgrade notices that and skips the download.

### The other two buttons

| File | What it does |
| --- | --- |
| `Fix Geode mods only.bat` | GD is already on 2.2081 but Geode or your mods are broken (for example, you updated mods by accident). Fixes only Geode and the mods. |
| `Undo GD downgrade.bat` | Lets Steam update GD to the newest version again, then moves Geode and your mods to the newest versions. Only do this once Geode supports the new GD. |

## What happens to your mods

For every mod in `geode\mods`, GD Downgrade checks which GD version and Geode version it was built for:

- **Already fits:** left alone.
- **Built for the wrong GD/Geode:** swapped for its newest version that fits, from the official [Geode mod index](https://geode-sdk.org/mods). Stable releases are picked over betas.
- **No version fits:** set aside in `geode\parked-mods`, not deleted. Geode can't see it there.
- **A mod needs a dependency you don't have:** the dependency is installed for you.

Every version a mod gets swapped away from is kept in `geode\parked-mods` too. When you switch GD versions later (with Undo, or by downgrading again), parked versions that fit come back first, so you get your exact versions back. That includes mods that aren't on the index, like ones you made yourself.

**Mega Hack** is a paid mod and isn't on the Geode index, so GD Downgrade can't swap it. If your Mega Hack doesn't fit the new GD version, it's parked like any other mod. Reinstall the right version with Mega Hack's own installer.

## Safety

- Your save (`%LOCALAPPDATA%\GeometryDash`), the Geode loader, your mods and Geode config are copied to a `GD downgrade backup <date>` folder on your Desktop before anything changes.
- Geode and mods download only from Geode's own servers (`api.geode-sdk.org`, `cdn.geode-sdk.org`). Every file is checked against its published SHA-256 hash before it's used.
- If the Geode step fails (say, no internet), the GD downgrade still finishes and your mods are left untouched. Run `Fix Geode mods only.bat` later.

## How it works

1. Backs up your save.
2. Has Steam download the 2.2081 depot (`download_depot 322170 322171 3816559102876907245`). That's why you paste a command into Steam's console: Steam only allows old depots to be downloaded from there.
3. Copies the 2.2081 files into your GD folder.
4. Marks GD's Steam app manifest read-only, so Steam doesn't update it back. (Steam's log will show "Access Denied" for that file. That's expected.)
5. Asks the Geode index for the newest Geode release for GD 2.2081, installs it, then fixes the mods as described above.

Everything is in two plain PowerShell scripts (`gd-downgrade.ps1`, `geode-sync.ps1`) that run on the PowerShell built into Windows. Read them before you run them.

## Troubleshooting

- **Steam says GD needs an update:** open `GeometryDash.exe` in the GD folder directly (keep Steam open).
- **"Steam couldn't download it":** make sure you own GD on the Steam account that's logged in.
- **A mod is missing after downgrading:** it has no 2.2081 version yet. It's in `geode\parked-mods` and comes back when you switch GD back.

Found a bug? [Open an issue](https://github.com/dan2756/gd-downgrade/issues) with a screenshot of the window.

---

Not affiliated with RobTop Games or the Geode team. Geode is at [geode-sdk.org](https://geode-sdk.org).
