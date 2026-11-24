# WoW Forever addons

Made for the Family, by Claude and EonJoe.

Three addons for the World of Warcraft **_forever_** client (interface 16001).

| Addon | Version | What it does |
|---|---|---|
| [Ledger](Ledger/) | 2.1 | Gold ledger: where every coin came from and went, by period and character, with search. **New:** a loot table (each character's own, or all together) of what each mob dropped and what it sold for, plus "who drops it" (type an item such as silk to see which mob drops the most), and a way to clear old data. Also an on-screen "coin earned" counter. `/ledger` or `/gl`. *Was called GoldLedger up to 1.3.* |
| [TidyBags](TidyBags/) | 2.6 | One bag window and a bank window (Character / Warband), with search, sort, saved bags and banks for every character, and item counts in tooltips. Profession bag slots get a light colour and the bag's icon. Both windows can be resized from the corner. **New:** saves errors and "blocked action" messages so problems can be fixed (`/tb errors`). `/tb` |
| [TidyChat](TidyChat/) | 1.4 | A "Tells" chat tab for whispers and party chat (offered on screen at first login), a "While you were away" list of what was said while you were AFK (each character has its own), a taskbar flash on whispers, and easier-to-read chat (no fading, timestamps, class colours). `/tc` |

## Install or update the addons (the easy way)

You need to do step 1 only once.

1. **Download the updater:**
   [Update-Addons.bat](https://github.com/ATHOMEAPPS/wow-forever-addons/releases/latest/download/Update-Addons.bat)
   Save it somewhere easy to find, such as your Desktop.

2. **Close World of Warcraft.** Log out and exit the game.

3. **Double-click `Update-Addons.bat`.** A black window opens and does the rest:
   - It finds your `_forever_` folder by itself. If it can't, it asks you to pick it once.
   - It downloads the newest addons and updates the ones you have.
   - The first time, it asks about each addon. **Just press Enter** to install it, or type `n` and Enter to skip it.
   - An addon you skip is remembered, so you won't be asked again. Changed your mind? At the end, type `A` and press Enter to add it.
   - At the end it lists what changed. Press Enter to close it.

4. **Start WoW** and play.

To update later, close WoW and double-click the updater again. That's all.

**"Windows protected your PC"?** Windows shows this the first time for files from the internet. Click **More info**, then **Run anyway**. You only have to do it once.

**Is my stuff safe?** Yes. The updater never touches your settings, your saved characters or your gold history. The old versions of the addons are kept in `%LOCALAPPDATA%\ForeverAddonsUpdater\backup`, just in case.

**GoldLedger is now called Ledger.** The updater moves your gold history across and removes the old GoldLedger folder for you.

**Something went wrong?** The window says what happened in plain words. Send a screenshot of it to EonJoe.

## Install by hand

1. Download the addon's zip (`Ledger/Ledger.zip`, `TidyBags/TidyBags.zip` or `TidyChat/TidyChat.zip`).
2. Close WoW and unzip it into `World of Warcraft\_forever_\Interface\AddOns\`.
3. Turn the addon on under "AddOns" at character select.

Each folder's `INSTALL.txt` has the full steps. If you had GoldLedger, see `Ledger/INSTALL.txt` step 3.
