// BootUnlock: the volume chooser.  update.sh runs it as
//
//     osascript -l JavaScript ui-choose.js FLAG LABEL [FLAG LABEL ...]
//
// FLAG is "1" when the volume is enrolled already (it is preselected) and "0"
// otherwise; LABEL is the text shown.  It prints "CANCEL", or "OK" followed by
// the positions (counting from 0) of the chosen labels, e.g. "OK 0 2".
//
// The labels contain volume names, which are untrusted.  They arrive as
// arguments and go back out as numbers; this file contains no text taken from
// a volume.

function run(argv) {
	var app = Application.currentApplication()
	app.includeStandardAdditions = true

	var labels = []
	var preselected = []
	for (var i = 0; i + 1 < argv.length; i += 2) {
		labels.push(argv[i + 1])
		if (argv[i] === '1') {
			preselected.push(argv[i + 1])
		}
	}

	var options = {
		withTitle: 'BootUnlock',
		withPrompt: 'Select the volumes BootUnlock unlocks at startup.  Hold the Command key to select several.  ' +
			'A volume you leave unselected is not unlocked, and its stored passphrase is removed.',
		multipleSelectionsAllowed: true,
		emptySelectionAllowed: true
	}
	if (preselected.length > 0) {
		options.defaultItems = preselected
	}

	try {
		app.activate()
	} catch (e) {
		// Showing the dialog behind another window is not fatal.
	}

	var picked
	try {
		picked = app.chooseFromList(labels, options)
	} catch (e) {
		return 'CANCEL'
	}
	if (picked === false || picked === null || picked === undefined) {
		return 'CANCEL'
	}

	var result = ['OK']
	for (var j = 0; j < picked.length; j++) {
		var position = labels.indexOf(picked[j])
		if (position >= 0) {
			result.push(String(position))
		}
	}
	return result.join(' ')
}
