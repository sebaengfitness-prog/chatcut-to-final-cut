# Optional project snapshot

ChatCut's NLE export may omit text graphics or transitions. A companion JSON file can record these omissions and supply the words and timing needed to rebuild text as editable Basic Titles. It is an input to the converter, not an automatic connection to ChatCut.

For `Export.xml`, save the companion as **`Export.warnings.json`** in the same folder. The CLI can select another file with `--warnings /path/to/snapshot.json`.

## Example

This is a synthetic example. Replace the SHA-256 placeholder with the digest of the exact XML file you will convert, and use text and frame values from that same edited timeline:

```json
{
  "sourceXMLSHA256": "REPLACE_WITH_THE_XML_FILES_64_CHARACTER_SHA256",
  "messages": [
    "The NLE export omitted one text graphic and one transition."
  ],
  "droppedItemTypes": {
    "motion-graphic": 1
  },
  "droppedTransitions": 1,
  "overlays": [
    {
      "assetName": "Caption example",
      "startFrame": 50,
      "durationInFrames": 75,
      "text": "A short example caption."
    }
  ]
}
```

Read the XML digest with:

```sh
shasum -a 256 "/path/to/Export.xml"
```

Use the first 64 hexadecimal characters. When `sourceXMLSHA256` is supplied, the converter checks it and rejects a mismatch, removing the newly created output files. Always include it for a handoff from an editing assistant. A snapshot without that field is accepted but cannot prove it belongs to the XML.

## Fields

| Field | Meaning |
| --- | --- |
| `sourceXMLSHA256` | Lowercase SHA-256 of the source XML's actual bytes. Recompute after each export. |
| `messages` | Strings added to the conversion report. |
| `droppedItemTypes` | Item-type names and omitted counts, carried into warnings. |
| `droppedTransitions` | Number of transitions omitted by the upstream export. They are reported, not reconstructed. |
| `overlays` | Text records with `assetName`, `startFrame`, `durationInFrames` and `text`. |

Frame positions are relative to the beginning of the sequence, using its frame rate. For example, at 25 fps the example starts at two seconds and lasts three seconds. Include each placed instance's effective text and timing, not only an asset's default properties. A reused graphic with different words needs separate records.

Asset names containing `caption` use the subtitle treatment; names containing `exercise` use the exercise-label treatment; other names use the general graphic-title treatment. This is a placement convention, not a reconstruction of the original design.

## Limits

The snapshot must be a JSON object smaller than 2,000,000 bytes. Recovery accepts at most 10,000 overlay records. Empty/oversized text and invalid or out-of-range timings are skipped; an overlay beginning after the exported sequence is also skipped. Review the recovered-title count in the report.

This format preserves supplied words and intervals. It does not reproduce motion design, background panels, exact font behavior, per-word highlighting or shaders. Native captions omitted from XML are not automatically enabled, imported or substituted. Preserve source export warnings and inspect the Final Cut result.

Snapshots can contain unpublished dialogue and project details. Create synthetic examples for public issues and never upload account tokens, authenticated media URLs or private project snapshots.
