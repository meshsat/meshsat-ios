// MeshSatMsvqsc: the MSVQ-SC semantic codec of MeshSat Android (crypto/MsvqscWire.kt,
// MsvqscCodebook.kt, SimpleWordPieceTokenizer.kt, the quantiser of MsvqscEncoder.kt). Decoding
// is pure Swift and runs on Linux; the sentence encoder (ONNX Runtime) lives in
// Packages/MeshSatApple because it needs the platform runtime.

public enum MeshSatMsvqsc {
    public static let module = "MeshSatMsvqsc"
}
