import Foundation
import Network
import Combine

/// Publishes whether the Mac currently has a usable network path, so the UI can show an offline state.
///
/// This reflects the system's view of connectivity (an interface with a route), not whether a particular
/// service is reachable.
public final class NetworkReachability: ObservableObject {
    public static let shared = NetworkReachability()

    /// True when a network path is available.
    @Published public private(set) var isOnline = true
    /// True on cellular/personal-hotspot style connections the system marks as expensive.
    @Published public private(set) var isExpensive = false
    /// True in Low Data Mode.
    @Published public private(set) var isConstrained = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.facet.cloud.reachability")

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isOnline != online { self.isOnline = online }
                if self.isExpensive != expensive { self.isExpensive = expensive }
                if self.isConstrained != constrained { self.isConstrained = constrained }
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
