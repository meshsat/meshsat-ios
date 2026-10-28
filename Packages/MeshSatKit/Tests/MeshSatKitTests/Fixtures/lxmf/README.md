# LXMF and Reticulum wire vectors

Two files, two writers, one wire format; the tests in `Tests/MeshSatKitTests/Rns` and `LXMF` read both.

- `golden.properties`: a verbatim copy of MeshSat Android's `app/src/test/resources/rns/golden.properties`,
  written by Python RNS 1.5.5 and LXMF 1.2.0 themselves (`scripts/rns-golden.py` in meshsat-android, the
  stack CrossTalk 2.6.0 ships). Keys, identities, tokens, HKDF, packets, announces, a message packed by
  Python (`lxmf.*`), one with fields and a stamp (`lxmf2.*`), announce app data. The Kotlin
  `GoldenVectorTest` and `LxmfGoldenTest` read the same bytes.
- `go-vectors.properties`: what the Bridge's Go code (`meshsat/internal/lxmf`, `msgpack`, `reticulum`)
  writes for the SAME keys with fixed timestamps: the Python message repacked by Go (`a_packed`, byte for
  byte the Python bytes), a message with a mid and an image and an audio attachment (`b_*`), the same with
  a Go-made stamp at cost 8 (`c_*`), Go's umsgpack golden value, the announce app data, and the two
  attachment maps of `fields_test.go`. Python LXMF 1.2.1 validated them before they were written here.

A Swift pack that equals `a_packed` or `b_packed` therefore equals Python's and Go's for those inputs;
an unpack of them is an unpack of a Go fixture. Every key and id here is made up and protects nothing.
