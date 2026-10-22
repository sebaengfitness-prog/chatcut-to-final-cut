# Public test fixtures

Everything in this directory was authored as synthetic test data. It contains no
personal projects, transcripts, media, account identifiers, or machine paths.

`linked-av.xml` models a 240-frame NTSC 23.976 sequence with six primary edits,
four connected edits (including genuine overlaps), and two independent sound
effects. Each camera edit has an explicitly linked audio partner. The converter
must create ten combined AV placements and two independent audio placements,
rather than duplicating the camera footage. Six gain envelopes contain 24 finite
gain keyframes.

`linked-av.warnings.json` is SHA-256 bound to that exact XML. Five example text
overlays exercise captions, labels, Unicode, XML escaping, placement on gaps, and
a final title extending three frames beyond the shorter exported sequence. Its
upstream omission warnings are deliberately synthetic.

Tests create temporary text placeholders for the three referenced media files.
Those files are never decoded or treated as playable media. Final Cut Pro is
not required. When its matching DTD is available, production conversion also
validates the generated XML against that locally installed DTD; otherwise the
tests cover the portable parsing, structure, and interchange behavior.

The negative `strokeWidth` title regression checks the serialization convention
used by this exporter. It is not a substitute for manually checking a new
Final Cut version's title appearance after import.

From the repository root, run `./scripts/test-converter.sh` and
`./scripts/test-titles.sh`. After `./scripts/build.sh`, run
`./scripts/test-cli.sh` to execute the built app's real `--help` and `--convert`
paths and verify the files it saves. All temporary data is deleted afterward.
Set `CHATCUT_EXPECT_NO_FCP=1` on a machine without Final Cut to additionally
assert that conversion reports the unavailable DTD and still succeeds.
