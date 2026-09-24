// MeshSatStore: persistence on Apple platforms. Mirrors data/AppDatabase.kt (Room v18 is iOS
// schema v1, same table and column names, GRDB migrations), data/SettingsRepository.kt (the
// DataStore keys, verbatim, in a UserDefaults suite) and crypto/SecureKeyStore.kt (Keychain).
import Foundation

public enum MeshSatStore {
    public static let module = "MeshSatStore"
    public static let settingsSuite = "net.meshsat.ios"
    public static let keychainService = "net.meshsat.ios.keys"
    public static let databaseFileName = "meshsat.sqlite"
}
