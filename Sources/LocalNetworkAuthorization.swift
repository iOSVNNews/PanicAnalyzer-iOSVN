//  LocalNetworkAuthorization.swift
//  Raises (and waits for) the Local Network prompt before advertising the
//  pairing host. Without the permission iOS silently drops our Bonjour
//  advertisement, so PanicAnalyzer never appears in Settings > Developer and
//  only other hosts (e.g. SideInstaller) are listed. Same trick as SideInstaller:
//  briefly advertise and browse a throwaway service; seeing it means granted.

import Foundation
import Network

final class LocalNetworkAuthorization {

    /// Must match an NSBonjourServices entry.
    static let probeType = "_panicanalyzerprobe._tcp"

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var completion: ((Bool) -> Void)?
    private var deadline: DispatchWorkItem?

    /// Call on the main queue; `completion` runs on the main queue once.
    func request(timeout: TimeInterval = 60, completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        finish(false)
        self.completion = completion

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let listener = try? NWListener(using: parameters)
        listener?.service = NWListener.Service(name: "PanicAnalyzerProbe-\(UUID().uuidString.prefix(8))",
                                               type: Self.probeType)
        listener?.newConnectionHandler = { $0.cancel() }
        listener?.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(false) }
        }
        self.listener = listener

        let browser = NWBrowser(for: .bonjour(type: Self.probeType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed:
                self?.finish(false)
            case .waiting(let error):
                // -65570 / NoAuth: the user tapped "Don't Allow".
                if case .dns(let code) = error, code == -65570 || code == -65555 { self?.finish(false) }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            if !results.isEmpty { self?.finish(true) }
        }
        self.browser = browser

        listener?.start(queue: .main)
        browser.start(queue: .main)
        let deadline = DispatchWorkItem { [weak self] in self?.finish(false) }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
    }

    private func finish(_ granted: Bool) {
        deadline?.cancel(); deadline = nil
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        listener?.stateUpdateHandler = nil
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        guard let completion else { return }
        self.completion = nil
        completion(granted)
    }
}
