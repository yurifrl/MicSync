import Foundation
import KeyboardShortcuts

// Shortcut names shown in Settings. Recording UX is KeyboardShortcuts'
// standard "click the recorder, press the combo" control.
extension KeyboardShortcuts.Name {
    static let toggleMic   = Self("toggleMic")                        // toggle
    static let muteMic     = Self("muteMic")                          // force muted
    static let unmuteMic   = Self("unmuteMic")                        // force live
    static let pushToTalk  = Self("pushToTalk")                       // hold = live, release = muted
    static let switchTarget = Self("switchTarget")                    // flip Meet/Slack when both live
}
