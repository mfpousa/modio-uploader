# Mod.io Uploader for UE4 🐱

A straightforward, interactive tool to upload and manage your Unreal Engine 4 mods on Mod.io without the command-line hassle.

## Setup

1. Drop the script files (`LaunchUploader.bat`, `UploadMods.ps1`, and `config.json`) into the folder containing your mod's `.zip` files. 
   *(The script expects files ending in `_pc.zip`, `_server.zip`, and `_android.zip`.)*
2. Open `config.json` and fill in your Mod.io `apiToken`, the `gameId` (e.g., `251` for Contractor$), and your `modId`.

## How to Use

Double-click **`LaunchUploader.bat`** to open the menu. The main menu includes a rich **Heads-up display** showing the live metadata of your mod, including the latest update time, active File IDs and file names for Win/Andr/Svr, and the most recent changelog right from the active target file!

Use your **Up/Down Arrow keys** and **Enter** to navigate the categorized menu.

### 1. Upload Mod
Automatically detects your local ZIP files (processing Windows, then Android, and finally Server), prompts you for an optional changelog, and confidently uploads everything to Mod.io via multipart upload.

### 2. Rollback / Update Metadata Only
If an upload breaks things, use this to fetch your past releases directly from Mod.io. Select an older, stable version from the list to revert your mod. The rollback process filters and intelligently hides files you have already selected across platforms.

### 3. Switch Mod
Instead of manually opening `config.json` every time you want to switch projects, select this option to fetch a list of all your mods dynamically, sorted by most recently updated. You can immediately start typing to **fuzzy-filter** the list to find the exact mod you're looking for. Hit `Enter` to switch contexts instantly.

### 4. Create Mod
Create a brand new mod right from the CLI. 
* It uses the **first `.png` file** in the script's folder as the mandatory Mod.io logo.
* Prompts for the `Name` and `Summary`.
* Offers an interactive multi-select menu (using `SPACE` to toggle and `ENTER` to submit) to assign tags (`Loadout`, `Windows`, `Android`, `Server`, `Map`, `CustomMode`).
* Formats the new mod correctly with the exact hidden metadata structure required by the game developers, guaranteeing the mod will be recognized in-game.

### 5. Edit Mod
Update your target mod's details actively without going to the Mod.io website.
* Allows inline editing of the **Name** and **Summary**.
* Opens the multi-select TUI to explicitly update **Tags**.
* Integrates a **Logo Update** option, grabbing the current `.png` in your folder and overwriting the live logo instantly.

### 6. Open in Mod.io
Need to check the mod page? This option extracts the profile URL right from the API and opens it in your default web browser instantly.
