// BootUnlock: the passphrase prompt.  update.sh runs it as
//
//     osascript -l JavaScript ui-passphrase.js MESSAGE
//
// It prints the passphrase that was typed, or nothing when the user chose
// "Skip" or closed the dialog.  MESSAGE contains a volume name, which is
// untrusted; it arrives as an argument and is only ever displayed.

function run(argv) {
	var app = Application.currentApplication()
	app.includeStandardAdditions = true

	try {
		app.activate()
	} catch (e) {
		// Showing the dialog behind another window is not fatal.
	}

	try {
		var answer = app.displayDialog(argv[0], {
			withTitle: 'BootUnlock',
			defaultAnswer: '',
			hiddenAnswer: true,
			buttons: ['Skip', 'Save'],
			defaultButton: 'Save',
			cancelButton: 'Skip'
		})
		return answer.buttonReturned === 'Save' ? answer.textReturned : ''
	} catch (e) {
		return ''
	}
}
