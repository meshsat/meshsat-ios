# Third-Party Notices, MeshSat iOS

MeshSat iOS is GPL-3.0 (see `LICENSE` and the README licence section). Swift
package dependencies and their licences are declared in the `Package.swift`
files and summarised in `NOTICE`. In addition, the repository vendors or ships
the following third-party material:

| Asset | Origin | Licence |
|---|---|---|
| `Vendor/protos/meshtastic/` (7 `.proto` files) | Meshtastic protobuf definitions (`meshtastic/protobufs`) | GPL-3.0, compiled into the shipped binary; this is why the app as a whole is GPL-3.0 |
| `Vendor/protos/takproto/` | TAK protobuf definitions, carried over from MeshSat Android | Needs verification before the first release |
| `App/MeshSat/Resources/Fonts/plex_*.ttf` (IBM Plex Sans 400/500/600, IBM Plex Mono 400/500) | IBM Plex (`github.com/IBM/plex`), the typeface of the MeshSat Bridge, Android app and brand | SIL Open Font License 1.1, Copyright 2017 IBM Corp., Reserved Font Name "Plex" |
| Material Icons under `Packages/MeshSatUI/Sources/MeshSatUI/Resources/Icons.xcassets/` | `google/material-design-icons`, imported by `scripts/import-material-icons.sh` at a pinned commit | Apache-2.0 |
| `Packages/MeshSatKit/Sources/MeshSatSatellite/Resources/tle/iridium-next.3le` | Iridium NEXT element sets from CelesTrak | Public orbital data, no licence restriction |
| The MeshSat mark (app icon, brand lockup) | The approved MeshSat mark, taken from the brand package without redrawing | MeshSat brand asset, not covered by the GPL; do not alter the mark |

Assets that arrive with later phases and their origins:

| Asset | Origin | Licence |
|---|---|---|
| `encoder.onnx` | INT8-quantised ONNX export derived from `sentence-transformers/all-MiniLM-L6-v2` | Apache-2.0 |
| `vocab.txt` | WordPiece vocabulary (30,522 tokens) from the BERT uncased tokenizer | Apache-2.0 |
| `world.mbtiles` | Natural Earth raster world basemap (z0 to z3) | Public domain (Natural Earth) |

`codebook_v1.bin` and `corpus_index.bin` are project-generated artefacts of the
MSVQ-SC semantic codec, not third-party material. All four MSVQ-SC assets are
data, not code, and come from one script in the MeshSat Bridge repository
(GPL-3.0): `sidecar/msvqsc/train.py` at `github.com/meshsat/meshsat`.
