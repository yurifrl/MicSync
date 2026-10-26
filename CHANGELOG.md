# Changelog

## 2026-10-26 Pairing URL Copy Button and LAN Hostname Fix

### Fixed
- Pairing URL in settings can be copied with a single click
- Phone pairing over LAN works on hosts whose machine name contains characters that are invalid in DNS hostnames
- Browser-based pairing clients get correct CORS answers so the pairing page loads instead of failing preflight

## 2026-10-26 Mute Commands No Longer Hit Other Participants

### Fixed
- Mic and camera commands in Google Meet now target only your own control in the bottom bar; pressing mute could previously hit a participant tile or panel row whose label matched first in the DOM
- Self-control lookup ignores labels inherited from nested elements, so participant tiles can no longer impersonate the mic button
- Status reads (mute state in the menu) use the same self-control selection, keeping reported state correct when tiles or rows are visible
