-- BootUnlock: a message box.  The BootUnlock scripts run it as
--
--     osascript ui-alert.applescript KIND MESSAGE
--
-- KIND is "critical" for an error; anything else shows an informational
-- message.  MESSAGE may contain volume names, which are untrusted; it arrives
-- as an argument and is only ever displayed.

on run argv
	set alertKind to item 1 of argv
	set alertText to item 2 of argv
	if alertKind is "critical" then
		display alert "BootUnlock" message alertText as critical
	else
		display alert "BootUnlock" message alertText as informational
	end if
end run
