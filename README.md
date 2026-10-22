# ChatCut to Final Cut

Bring an edited ChatCut timeline into Final Cut Pro as editable clips, using your original media. This small Mac app converts ChatCut's Premiere Pro / FCP7 XML export into FCPXML and writes a report of missing media and translation limits.

**[Download the latest release](https://github.com/sebaengfitness-prog/chatcut-to-final-cut/releases/latest)** · [Compatibility](docs/COMPATIBILITY.md) · [Optional text snapshot](docs/SNAPSHOT.md) · [Changelog](CHANGELOG.md)

## Install

Requires **macOS 13 or later**. Version 1.1.0 includes Apple silicon and Intel code in one universal app. Apple silicon has been tested; Intel hardware has not yet been tested. Final Cut Pro is needed to import and finish the edit, but is **not required to convert XML**.

1. Open the [latest release](https://github.com/sebaengfitness-prog/chatcut-to-final-cut/releases/latest) and expand **Assets**.
2. Download `ChatCut-to-Final-Cut-1.1.0-universal.dmg` or `ChatCut-to-Final-Cut-1.1.0-universal.zip`. GitHub's automatically generated **Source code** archives contain code to build, not the ready-to-run app.
3. Open the DMG, or unzip the app ZIP. Drag **ChatCut to Final Cut.app** into **Applications** or your home folder's **Applications** folder.
4. Open the app.

The downloadable app is **ad-hoc signed and not notarized**. Its signature does not establish a verified developer identity or Apple review, and macOS may block its first launch. If you trust the release you downloaded, first try opening it, then go to **System Settings → Privacy & Security → Open Anyway** and confirm **Open**. Managed Macs may restrict this option. Follow [Apple's official instructions](https://support.apple.com/en-us/102445); do not disable Gatekeeper globally.

The release includes `SHA256SUMS.txt` so you can compare the downloaded file's checksum with `shasum -a 256 /path/to/download.dmg`. A matching checksum checks the download against the published file; it does not replace notarization.

## Transfer an edit

1. In ChatCut, export the edited timeline as **NLE XML for Premiere Pro**. Extract an archive export before continuing.
2. Choose or drop the exported `.xml` file into this app.
3. Add the folders containing the camera originals and any downloaded generated audio or graphics.
4. Click **Convert to Final Cut**. Review the report, including missing media and omitted elements.
5. Click **Open in Final Cut Pro** and choose a destination library in Final Cut.

Each conversion creates a new `.fcpxml` and `.report.json`; existing output names get numbered alternatives. The app leaves your source XML and media unchanged. It does not edit the ChatCut project. Media stays in its current location, so keep its drive and folders available after import.

If ChatCut omitted text from its XML, a matching optional [snapshot](docs/SNAPSHOT.md) can rebuild the words and timing as editable **Basic Titles**. These approximate placement and styling; they do not reproduce motion graphics, panels, word highlighting or custom shaders. The app cannot recover details absent from both XML and snapshot.

**Watch export inbox** converts completed XML files placed in `~/Movies/ChatCut to Final Cut/Inbox` while the app is open, using your selected media folders. It checks for a stable file size and modification time between scans. Opening Final Cut remains a separate action.

## Command line

The executable inside the app can be used by scripts or an editing assistant after obtaining a fresh ChatCut export:

```sh
"/Applications/ChatCut to Final Cut.app/Contents/MacOS/ChatCutToFinalCut" \
  --convert "/path/to/Export.xml" \
  --media-root "/path/to/camera originals" \
  --media-root "/path/to/generated media" \
  --output-dir "$HOME/Movies/ChatCut to Final Cut"
```

Adjust the app path if you installed it in `~/Applications`. Repeat `--media-root` for additional folders. The command prints a JSON result and exits without opening Final Cut. Use `--warnings /path/to/Export.warnings.json` for an explicit snapshot or `--help` for options. To show a saved report in the app:

```sh
open -a "/Applications/ChatCut to Final Cut.app" --args \
  --show-result "/path/to/Project.report.json"
```

The standalone app does not connect to a ChatCut account or export projects from the service. ChatCut or an authenticated connector supplies the interchange file.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| App blocked at launch | See the first-launch instructions above. If macOS says the file is damaged or harmful, download a fresh release and review Apple's guidance rather than bypassing that alert. |
| Missing or offline media | Add the correct source folders, reconnect the drive, then convert again. Ambiguous filename matches require a more specific folder or manual relinking in Final Cut. |
| No Final Cut DTD found | Conversion can still run. Install Final Cut in its standard Applications location for the strongest available schema check. Review the warning before importing. |
| Snapshot belongs to another export | Obtain fresh XML and a snapshot from that same edit. A supplied SHA-256 mismatch is rejected. |
| Missing titles, transitions or effects | Read the report and [compatibility limits](docs/COMPATIBILITY.md). Data omitted by ChatCut cannot be inferred reliably. |
| Final Cut import differs from the preview | Report a minimal synthetic example. Valid XML is only the first check; actual import, playback and audio review matter. |

## Privacy

Conversion runs locally. The app has no built-in account login, upload, analytics or telemetry feature. **Open ChatCut** opens its website in your browser. Selected media folders and the output folder are remembered in local app preferences.

FCPXML and reports contain project names, filenames and local paths; a snapshot may contain your subtitles or other unpublished text. Review and redact those files before sharing them in a public issue. Originals and exports are not bundled into the app.

## Build and contribute

Install the macOS Command Line Tools, clone this repository, and run:

```sh
xcode-select --install
git clone https://github.com/sebaengfitness-prog/chatcut-to-final-cut.git
cd chatcut-to-final-cut
chmod +x scripts/*.sh
./scripts/test-converter.sh
./scripts/test-titles.sh
./scripts/build.sh
./scripts/test-cli.sh
```

Create fresh release archives and checksums with `./scripts/package.sh`. The build and tests use only Apple system frameworks and Command Line Tools; the repository's fixtures are synthetic and do not contain footage.

The build writes `build/ChatCut to Final Cut.app`. To build and install into `~/Applications`, preserving an existing app under a dated previous-version name, run `./scripts/install.sh`.

Contributions should include a small synthetic XML example and focused regression coverage for timeline changes. Test both XML structure and actual Final Cut import when a change affects import behavior. Avoid uploading real projects, footage, account data, private reports, or Apple/proprietary application resources. [Open an issue](https://github.com/sebaengfitness-prog/chatcut-to-final-cut/issues/new/choose) with the app version, macOS version, architecture and a reproducible example.

Source code is licensed under [MIT](LICENSE). This is an independent project; it is not affiliated with or endorsed by ChatCut or Apple.
