import Foundation
import AppKit

// Meet backend: drives the Google Meet tab in Chrome by injecting JS via
// AppleScript. Every osascript run is an asynchronous /usr/bin/osascript
// subprocess — a slow AppleScript must never block the main run loop.

final class MeetAdapter: SessionAdapter {
    let kind: SessionKind = .meet

    // Chrome requires one-time setup: View > Developer > Allow JavaScript
    // from Apple Events. Surfaced once, via notification, when detected.
    static let micSetupIssue = Notification.Name("MicSetupIssue")

    private static let chromeBundle = "com.google.Chrome"
    private static let meetURLMarker = "meet.google.com"

    // ----------------------------------------------------------
    // JS templates (ported from meet-mic.lua verbatim; single quotes
    // only -> no escaping needed inside the AppleScript string literal)
    // ----------------------------------------------------------

    // Find the control-bar mic button and the leave-call button.
    private static let FINDER_JS =
        "var b=document.querySelectorAll('button,[role=button]'),mic=null,leave=null;" +
        "for(var i=0;i<b.length;i++){var e=b[i],l=e.getAttribute('aria-label')||e.textContent||'';" +
        "if(!mic&&/microphone|microfoon|mikrofon|micrófono|microfone/i.test(l))mic=e;" +
        "if(!leave&&/leave|end call/i.test(l))leave=e;}"

    // Read-only: whether this tab holds an active call and the mic state.
    // "live" = mic is on (label asks to turn it off), "muted" = mic is off.
    private static let PROBE_JS =
        "(function(){" + FINDER_JS +
        "if(!mic&&!leave)return JSON.stringify({inCall:false,found:false});" +
        "var ml='',st='unknown';if(mic){ml=mic.getAttribute('aria-label')||'';" +
        "if(/turn on|unmute|inschakelen/i.test(ml))st='muted';" +
        "else if(/turn off|mute|uitschakelen/i.test(ml))st='live';}" +
        "return JSON.stringify({inCall:!!leave,found:!!mic,state:st});})()"

    // Action: click the mic button only when the action actually changes
    // state. Returns the literal SKIP when the tab is not in a call.
    private static func actJS(action: String) -> String {
        "(function(){var a='" + action + "';" + FINDER_JS +
        "if(!leave)return 'SKIP';" +
        "if(!mic)return JSON.stringify({ok:false,reason:'no-mic-button'});" +
        "var ml=mic.getAttribute('aria-label')||'',st='unknown';" +
        "if(/turn on|unmute|inschakelen/i.test(ml))st='muted';" +
        "else if(/turn off|mute|uitschakelen/i.test(ml))st='live';" +
        "var need=(a=='toggle'&&(st=='muted'||st=='live'))||" +
        "(a=='mute'&&st=='live')||(a=='unmute'&&st=='muted');" +
        "if(need)mic.click();" +
        "return JSON.stringify({ok:need,clicked:need,state:st,label:ml});})()"
    }

    // Single AppleScript that scans every window/tab URL, then executes JS
    // in the FIRST meet.google.com tab it finds (any window). One
    // subprocess round-trip per operation.
    private static func meetScript(js: String) -> String {
        """
        tell application "Google Chrome"
          set found to false
          repeat with w from 1 to count of windows
            set tcount to count of tabs of window w
            repeat with t from 1 to tcount
              if URL of tab t of window w contains "\(meetURLMarker)" then
                set found to true
                set theResult to execute tab t of window w javascript "\(js)"
                exit repeat
              end if
            end repeat
            if found then exit repeat
          end repeat
          if not found then return "NOTAB"
          return theResult
        end tell
        """
    }

    // ----------------------------------------------------------
    // AppleScript plumbing
    // ----------------------------------------------------------

    private let queue = DispatchQueue(label: "com.yurifrl.micsync.meet", qos: .userInitiated)
    private var setupIssuePosted = false

    private func chromeRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeBundle).isEmpty
    }

    // Run one AppleScript snippet in a subprocess; cb(stdout, errString|nil).
    // osascript prints list results as a comma-separated single line, so
    // the tabs-by-window scan walks a flattened list; window boundaries are
    // not needed because act/probe target "the first Meet tab" via the
    // combined execute.
    private func runASAsync(_ script: String, cb: @escaping (String, String?) -> Void) {
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.qualityOfService = .userInitiated

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            var outData = Data()
            var errData = Data()
            let lock = NSLock()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                lock.lock(); outData.append(handle.availableData); lock.unlock()
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                lock.lock(); errData.append(handle.availableData); lock.unlock()
            }

            process.terminationHandler = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                lock.unlock()
                cb(out, process.terminationStatus != 0 ? (err.isEmpty ? out : err) : nil)
            }

            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cb("", "\(error)")
            }
        }
    }

    // Run JS in the first Meet tab; cb(outString|nil, errString|nil).
    private func jsOnFirstMeetTab(_ js: String, cb: @escaping (String?, String?) -> Void) {
        runASAsync(Self.meetScript(js: js)) { [weak self] out, err in
            guard let self else { return }
            if let err {
                checkSetupError(err)
                return cb(nil, err)
            }
            if out.contains("NOTAB") { return cb(nil, nil) }
            cb(out, nil)
        }
    }

    private func checkSetupError(_ err: String) {
        guard err.contains("turned off"), !setupIssuePosted else { return }
        setupIssuePosted = true
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.micSetupIssue,
                object: nil,
                userInfo: [
                    "message": "In Chrome enable View > Developer > Allow JavaScript from Apple Events",
                    "kind": SessionKind.meet,
                ]
            )
        }
    }

    // ----------------------------------------------------------
    // JSON decoding of the JS payloads
    // ----------------------------------------------------------

    private struct ProbeJSON: Decodable {
        let inCall: Bool
        let state: String?
    }

    // The JS already classifies via the aria-label regexes and reports
    // 'live' | 'muted' | 'unknown'; map those strings directly.
    private func micState(fromState raw: String?) -> MicState {
        switch raw {
        case "live": return .live
        case "muted": return .muted
        default: return .unknown
        }
    }

    // Extract the first JSON object from osascript output (it may carry
    // surrounding whitespace/newlines).
    private func extractJSON(from out: String) -> Data? {
        guard let start = out.firstIndex(of: "{"),
              let end = out.lastIndex(of: "}"), start < end else { return nil }
        return String(out[start...end]).data(using: .utf8)
    }

    // ----------------------------------------------------------
    // SessionAdapter
    // ----------------------------------------------------------

    func probe(_ cb: @escaping (SessionSnapshot?) -> Void) {
        guard chromeRunning() else { return cb(nil) }
        jsOnFirstMeetTab(Self.PROBE_JS) { [weak self] out, err in
            if let err {
                self?.checkSetupError(err)
                return cb(nil)
            }
            guard let self, let out,
                  let data = self.extractJSON(from: out),
                  let payload = try? JSONDecoder().decode(ProbeJSON.self, from: data) else {
                return cb(nil)
            }
            let state: MicState = self.micState(fromState: payload.state)
            cb(SessionSnapshot(kind: .meet, inCall: payload.inCall, state: state))
        }
    }

    func set(_ desired: MicState, cb: @escaping (Bool) -> Void) {
        guard chromeRunning() else { return cb(false) }
        let action = desired == .muted ? "mute" : "unmute"
        jsOnFirstMeetTab(Self.actJS(action: action)) { [weak self] out, err in
            if let err {
                self?.checkSetupError(err)
                return cb(false)
            }
            guard let self, let out else { return cb(false) }
            if out.trimmingCharacters(in: .whitespacesAndNewlines) == "SKIP" {
                return cb(false) // not in a call
            }
            // The click settles asynchronously in the DOM; verify by
            // re-probe: success = resulting state == desired.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return cb(false) }
                self.probe { snapshot in
                    cb(snapshot?.inCall == true && snapshot?.state == desired)
                }
            }
        }
    }
}
