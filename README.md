# Mod.io Uploader for UE4 🐱

A straightforward, interactive tool to upload and manage your Unreal Engine 4 mods on Mod.io without the command-line hassle.

## Setup

1. Drop the script files (`LaunchUploader.bat`, `UploadMods.ps1`, and `config.json`) into the folder containing your mod's `.zip` files. 
   *(The script expects files ending in `_pc.zip`, `_server.zip`, and `_android.zip`.)*
2. Open `config.json` and fill in your Mod.io `apiToken`, the `gameId` (e.g., `251` for Contractor$), and your `modId`.

## How to Use

Double-click **`LaunchUploader.bat`** to open the menu. The main menu now includes a "Heads-up display" showing the current live metadata of your mod, including latest update time, active File IDs for Win/Andr/Svr, and the most recent changelog right from the active target file!

Use your **Up/Down Arrow keys** and **Enter** to navigate. 

### 1. Upload Mod
Automatically detects your local ZIP files (processing Windows, then Android, and finally Server), prompts you for an optional changelog, and confidently uploads everything to Mod.io while you go pet your cat.

### 2. Rollback / Update Metadata Only
If an upload breaks things, use this to fetch your past releases directly from Mod.io. Select an older, stable version from the list to revert your mod and get your players back up and running quickly. The rollback process intelligently hides files you have already selected and prompts you for the Windows PC version first, then Android, and finally Server.

### 3. Change Target Mod.io Mod
Instead of manually opening `config.json` every time you want to switch projects, select this option to fetch all the mods you own dynamically from the Mod.io server. When you choose a mod from the interactive list, the utility instantly switches its context, caching your new target into the configuration for you.
