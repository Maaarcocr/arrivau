# Third-party components and data

The root [LICENSE](LICENSE) applies to Arrivau's original code and documentation.
It does not relicense or restrict third-party components or data.

The following is a **partial, verified source-dependency notice**, not an
exhaustive inventory for distributing native binaries, SDKs, containers or maps:

- **OSRM 6.0.0**: Project OSRM's two-clause BSD license. The pinned source is
  commit `054b0a6395f689a47a908b26b12e32ed7704c533`; see its
  [original LICENSE.TXT](https://github.com/Project-OSRM/osrm-backend/blob/v6.0.0/LICENSE.TXT).
  The build helper preserves that complete notice at `share/osrm/LICENSE.TXT`
  in the generated local SDK. The upstream source archive, including its original
  third-party notice files, remains in the chosen build directory
- **osrm_interface 0.8.2**: the optional native Rust bridge declares MIT in its
  [published crate metadata](https://crates.io/crates/osrm_interface/0.8.2).
  The dependency is pinned in Cargo.toml/Cargo.lock; its source is not vendored or
  relicensed by this repository
- **OpenStreetMap data**: © OpenStreetMap contributors, available under
  [ODbL 1.0](https://www.openstreetmap.org/copyright).
  Prepared map data is not checked in. The preparation script writes attribution
  beside the generated graph; the API and app retain map attribution and source
  date, including mixed road/approximate estimates

OSRM's native build also uses dependencies such as Boost, TBB, the C++ runtime,
compression/XML libraries and Lua, along with bundled header libraries. Their
individual notices and applicable distribution obligations are **not** fully
inventoried by this document. Other Rust and app dependencies retain their own
licenses as well.

Before publishing or distributing a native binary, SDK/container or derived map
bundle, produce and verify a complete notice/license inventory for that exact
artifact. The native CI workflow deliberately does not cache or upload generated
SDKs/binaries under this partial notice set. Public source visibility does not
make Arrivau's original code open source.
