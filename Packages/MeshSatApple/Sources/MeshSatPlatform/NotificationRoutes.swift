// The route a notification tap asks for (MainActivity's EXTRA_ROUTE on Android): the app delegate
// hands it here, RootView takes it and opens the screen, also when the tap launched the app and the
// views were not there yet (the value waits until it is taken).
import MeshSatNet

public enum NotificationRoutes {
    /// "sos", "warnings", "messages", "home", or nil once taken.
    public static let pending = StateBroadcast<String?>(nil)
}
