-- Presses the launcher's PLAY button the way a player does: through the accessibility tree if Swing exposes the
-- button there, otherwise a mouse click on its place (the launcher window is fixed-size; PLAY sits 40% across and
-- 81% down the window, title bar included). Prints which way it went.
on run
	tell application "System Events"
		tell process "Vanguard"
			set frontmost to true
			delay 1
			set w to window 1
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
			set cx to px + (sx * 0.405)
			set cy to py + (sy * 0.814)
			click at {cx, cy}
			return "click-at " & cx & "," & cy & " (window " & px & "," & py & " " & sx & "x" & sy & ")"
		end tell
	end tell
end run
