# TeRRaDuDe RAWG Game Database – Eggdrop Tcl Script

**Version:** 1.0.14  
**Platform:** Eggdrop 1.9.x / Tcl 8.6+  
**Game Database:** [RAWG Video Games Database](https://rawg.io/)  
**Supported Platforms:** PC, PlayStation, Xbox, Nintendo Switch, iOS and Android.

## Overview

TeRRaDuDe RAWG Game Database is an Eggdrop Tcl script that integrates the RAWG Video Games Database API into IRC.

The script allows users to search for video games directly from IRC and automatically announce game information when new releases are uploaded to configured glFTPd directories.

It uses intelligent release-name normalization and search-result matching to improve game identification and reduce incorrect RAWG matches.

## Features

### Manual Game Search
- Search for games directly from IRC using a configurable public command.
- Retrieve detailed game information from RAWG.
- Search games using their RAWG database ID.
- Preview automatic release announcements before publishing them.

### Automatic Release Announcements
- Integrates with PZS-NG through the NEWDIR event.
- Automatically detects new releases in configured directories.
- Supports multiple announcement directories and IRC channels.
- Converts scene release names into searchable game titles.
- Automatically retrieves and announces matching game information.
- Suppresses unsuccessful automatic lookup messages in IRC channels.

### Intelligent Release Name Processing
- Removes scene release group names.
- Removes platform identifiers such as PS5, NSW and Xbox.
- Removes update information and version numbers.
- Removes trainer information, DLC metadata, REPACK, PROPER and READNFO tags.
- Removes trailing release years when appropriate.
- Preserves meaningful game title information.

### RAWG Search Result Matching
- Evaluates multiple RAWG search results.
- Compares normalized title keywords.
- Prioritizes relevant title matches.
- Rejects unrelated partial matches to reduce false game identification.

### Game Information
Depending on the configuration, announcements can include:

- Game title
- RAWG database ID
- Release date
- Genres
- Available platforms
- Metacritic score
- User rating
- Official website
- Developers
- Publishers
- ESRB rating
- RAWG game URL
- Game description

### Performance and Reliability
- Asynchronous HTTP requests.
- HTTPS support through Tcllib TLS.
- Configurable request timeout and retry handling.
- Optional response caching.
- Configurable announcement delay.
- Fast IRC output using Eggdrop's `putquick`.
- HTTP callback diagnostics and optional debug logging.
- Automatic PZS-NG registration with retry handling.
- Clean event and command binding removal during rehash or restart.

## IRC Commands

| Command | Description |
|---|---|
| `!game <game name>` | Search RAWG for a game. |
| `!gameid <RAWG ID>` | Retrieve game information using its RAWG ID. |
| `!rawgpreview <release>` | Preview a release announcement. |

The main game search command is configurable and can be changed to commands such as `!gameinfo`, `!game` or `!info`.

## Requirements

- Eggdrop 1.9.x
- Tcl 8.6 or newer
- Tcllib HTTP package
- Tcllib JSON package
- Tcl TLS package
- A valid RAWG API key
- PZS-NG for automatic NEWDIR integration

## Configuration

The script provides configurable options for:

- RAWG API key and API endpoint
- Public command trigger
- Automatic announcements
- Announcement channels
- Monitored glFTPd directories
- Announcement formatting
- Displayed game information
- Description length
- HTTP timeout and retries
- Cache settings
- Debug logging
- Command access restrictions

## Installation

1. Install the required Tcl packages.
2. Obtain a RAWG API key.
3. Configure the API key in the script.
4. Configure announcement channels and glFTPd directories.
5. Load the script into Eggdrop.
6. The script automatically registers its PZS-NG NEWDIR handler.

---

**TeRRaDuDe RAWG Game Database**  
*Bringing video game information and automatic release announcements directly to IRC.*
