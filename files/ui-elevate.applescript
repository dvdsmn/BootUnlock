-- BootUnlock: runs one of its own scripts as root after asking for an
-- administrator name and password.  update.sh and uninstall.sh run it as
--
--     osascript ui-elevate.applescript /absolute/path/of/script PROMPT
--
-- The path arrives as an argument and is quoted for the shell by AppleScript
-- itself, so nothing in it is interpreted.

on run argv
	do shell script (quoted form of item 1 of argv) with prompt (item 2 of argv) with administrator privileges
end run
