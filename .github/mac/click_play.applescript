-- Presses the launcher's PLAY button the way a player does: through the accessibility tree if Swing exposes the
-- button there, otherwise a mouse click on its place. Two launcher windows exist:
--   the classic window (fixed size, ~840 wide): PLAY sits 40% across and 81% down, title bar included;
--   launcher v2 (2026-10-29, Vanguard-Launcher-UI.jar: a 1120x700 borderless window plus the docked deals window):
--   PLAY sits 72% across and 44% down the main window. The main window is the widest one.
-- Prints which way it went.
on run
	tell application "System Events"
		tell process "Vanguard"
			set frontmost to true
			delay 1
			set w to window 1
			try
				repeat with candidate in windows
					set {cw, ch} to size of candidate
					set {bw, bh} to size of w
					if cw > bw then set w to candidate
				end repeat
			end try
			try
				repeat with e in (entire contents of w)
					try
						if role of e is "AXButton" then
							set t to ""
							try
								set t to (title of e) as text
							end try
							set n to ""
							try
								set n to (name of e) as text
							end try
							if t contains "PLAY" or n contains "PLAY" then
								click e
								return "ax-button " & t & n
							end if
						end if
					end try
				end repeat
			end try
			set {px, py} to position of w
			set {sx, sy} to size of w
			if sx > 1000 then
				set cx to px + (sx * 0.716)
				set cy to py + (sy * 0.443)
				set layout to "v2"
			else
				set cx to px + (sx * 0.405)
				set cy to py + (sy * 0.814)
				set layout to "classic"
			end if
			click at {cx, cy}
			return "click-at " & cx & "," & cy & " (" & layout & " window " & px & "," & py & " " & sx & "x" & sy & ")"
		end tell
	end tell
end run
