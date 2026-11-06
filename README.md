<p align="center"><img src="assets/logo.png" width="256" alt="Mirra's Threat"></p>

# Mirra's Threat

A lightweight WoW Forever addon that shows your threat on enemy nameplates as a compact bar and/or percentage, colored for your role.

## Features

- Threat bar and percentage below every enemy nameplate, styled like the resource bars: rounded frame, glossy fill
- **Part of the nameplate** (default): the bar sits directly under the health bar in Blizzard's own nameplate look (same bar art, background and font), inside the yellow target border and darkened like the health bar when the enemy is not your target. The percentage is inside the bar; height, width, font size and gap are adjustable. When the enemy casts, its cast bar appears below the threat bar instead of pushing it away. Works with every Blizzard nameplate size (small to huge) and style (modern and classic); the bar height scales with the nameplate
- Other nameplate addons: the bar falls back to the floating style below the nameplate
- Role-aware colors
  - **Tank:** green while you hold aggro, yellow when losing it, red once lost
- **Tank extras**
  - **Insecure aggro warning:** while you are tanking but someone else already has more threat, the bar turns orange and pulses
  - **Who has aggro:** after you lose aggro, the name of the player the enemy is attacking appears below the bar
  - **DPS / Healer:** green while safe, yellow when close to pulling, red once you pull aggro
- Three styles: bar + text, bar only, text only
- Text position inside the bar: left, center or right
- Adjustable attached bar height; for the floating style width, bar height, font size and vertical offset; warning threshold
- Optional: hide at 0 % threat, only show while in a group
- Settings panel with live preview under **Options → AddOns → Mirra's Threat**
- Works with WoW Forever secret values (Interface 16001)

## Installation

Copy the addon into your WoW Forever `Interface/AddOns/MirraThreat/` folder
(the folder must be named `MirraThreat`, matching `MirraThreat.toc`).

## Commands

| Command          | Description                    |
|------------------|--------------------------------|
| `/mthreat`       | Open the settings              |
| `/mthreat tank`  | Switch to tank colors          |
| `/mthreat dps`   | Switch to DPS / healer colors  |
| `/mthreat debug` | Print debug information        |
