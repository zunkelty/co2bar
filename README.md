# CO2 Bar

A macOS menu bar app that shows the current CO₂ level from a Honeycomb board, e.g. **● 1024 ppm**.

It reads the newest CO₂ value every minute.

- **Green:** below 750 ppm.
- **Amber:** 750 to 1000 ppm.
- **Red:** above 1000 ppm. Open a window.
- **Grey:** the newest reading is more than 5 minutes old.

## Requirements

- macOS 13 or later.
- A Honeycomb account that can see a board with a CO₂ query. For example, a board name like "CO2 (ppm)" with a query on a column like `co2_ppm`.
- The link to that board. Ask your team for it. The app keeps it in your Keychain, not in this repo.
- The Xcode Command Line Tools. The app is built on your Mac, so you need no Apple developer account and get no Gatekeeper warnings.

## Install with an agent

Give this prompt to Claude Code or another coding agent:

```text
Install the CO2 Bar menu bar app from https://github.com/zunkelty/co2bar on this Mac.

1. Run `xcode-select -p`. If it fails, run `xcode-select --install`, ask me to finish the installer, and wait until `xcode-select -p` succeeds.
2. If ~/co2bar exists, run `git -C ~/co2bar pull`. If not, run `git clone https://github.com/zunkelty/co2bar.git ~/co2bar`.
3. Run `~/co2bar/build.sh install`. This builds the app, copies it to ~/Applications/CO2Bar.app and starts it.
4. Tell me that the app shows a window that asks for a Honeycomb board link. I must paste the link to our CO₂ board and click Save. Do not ask me for the link yourself.
5. Tell me that a Honeycomb sign-in tab then opens in my browser and that I must approve it. Wait until `security find-generic-password -s com.github.zunkelty.co2bar -a honeycomb-mcp` succeeds. That means the sign-in is done.
6. Tell me to check that the menu bar shows a CO₂ value in ppm. Tell me to click it and turn on "Launch at Login".

If a step fails, show me the error and stop.
```

## Install by hand

```sh
git clone https://github.com/zunkelty/co2bar.git ~/co2bar
~/co2bar/build.sh install
```

1. Paste the board link in the window that opens, and click **Save**.
2. Approve the Honeycomb sign-in in your browser.
3. Click the value in the menu bar and turn on **Launch at Login**.

To update, run `git -C ~/co2bar pull && ~/co2bar/build.sh install`. After an update, macOS can ask once if CO2 Bar can use its Keychain items. Click **Always Allow**.

To use a different board, click **Change Board…** in the menu.

## Uninstall

1. In the menu, turn off **Launch at Login** and click **Sign Out of Honeycomb**.
2. Quit the app.
3. Run these commands:

```sh
security delete-generic-password -s com.github.zunkelty.co2bar -a board
rm -rf ~/Applications/CO2Bar.app ~/co2bar
```

## How it works

1. The board link gives the Honeycomb region, environment and board ID.
2. The app signs in to the Honeycomb MCP server for that region (`mcp.honeycomb.io` or `mcp.eu1.honeycomb.io`) with OAuth in your browser. It does not need an API key.
3. It finds the first query on the board with "CO2" in its name, and gets the dataset and the CO₂ column from that query.
4. Each minute it uses the `run_query` tool to get that column's values from the last 10 minutes, and it shows the newest one.

The app saves the board link, the sign-in token, the dataset and the column in your Keychain.
