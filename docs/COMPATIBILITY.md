# Compatibility

## Platform

Version 1.1.0 targets macOS 13 and later and includes **arm64** and **x86_64** in a universal app. Runtime testing has been on Apple silicon; Intel hardware is untested. The release is locally ad-hoc signed, with no Developer ID signature or Apple notarization.

Final Cut Pro is not required to create FCPXML. If the matching DTD is present in the standard Final Cut Pro or Final Cut Pro Trial installation under `/Applications`, the app validates against it using the local `xmllint` tool. Otherwise it reports that schema validation was unavailable. A successful parse or DTD check does not establish correct playback or full edit equivalence.

Real import checks have used Final Cut Pro 12.3. Other versions have not been exhaustively tested. Legacy conversion writes **FCPXML 1.10**. Native FCPXML relinking retains the input's declared version rather than upgrading or downgrading it.

## Interchange behavior

| Data | Supported behavior and limits |
| --- | --- |
| Input | Plain ChatCut Premiere/FCP7 `xmeml` export containing one supported sequence, or native `.fcpxml` for relinking. Extract ZIP exports first. Native editor project databases are not read. |
| Cuts and layers | Source trims, offsets, gaps, separate video/audio lanes and enabled state. Overlapping primary-track edits use connected clips above a gap. |
| Linked camera audio | Unique reciprocal links with matching source, ranges, timing and state become one editable AV placement. Independent or mismatched edits remain component-specific clips. |
| Audio levels | Static gain and supported volume keyframes become decibel adjustments. Zero gain uses a finite floor or audio-component mute. Interpolation can sound different from ChatCut. |
| Channels and streams | Default source audio is the best-covered case. Complex multichannel, mixed source-track metadata and routing require review. |
| Timing | Rational frame times, source timecode, timeline timecode and NTSC rates. Upstream frame-count errors are not automatically repaired. |
| Speed | Constant source-to-timeline mappings, including supported reverse timing. Variable speed is approximated by endpoints and reported. |
| Text snapshot | Words and exact supplied frame intervals become editable Basic Titles, with approximate font, position, outline and shadow. Filled text uses the verified negative stroke-width convention. |
| Effects and graphics | ChatCut-specific effects, transitions, animation, panels, custom shaders and word highlighting are not recreated. Unsupported exported elements produce warnings where detected; omissions upstream may require the companion warnings file to identify. |
| Native FCPXML | Existing XML editing/effect structure is retained during media relinking. This does not make unavailable plugins, fonts or assets available on the destination Mac. |

Some legacy constructs, including nested sequences and generated items, are unsupported or omitted with warnings. Review every report rather than treating this table as a guarantee for arbitrary Premiere or FCP7 exports.

## Media and fidelity

The app resolves existing media paths, relative paths, then unique filename matches inside the selected search folders. It does not transcode media or copy it into a portable project package. Final Cut must be able to read the referenced files and codecs.

For an important transfer, compare the imported project's duration, representative source trims, titles, transitions and audio against the source edit. The source XML, report, and a fresh matching snapshot are useful evidence. A rendered graphic can preserve appearance if supplied separately, but the converter does not render ChatCut graphics itself.
