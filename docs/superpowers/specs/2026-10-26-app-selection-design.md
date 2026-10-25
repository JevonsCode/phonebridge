# App selection correction

The owner requested a checkbox instead of the one-way Select all text button and removal of the arbitrary 64-app ceiling.

Use a trailing tri-state checkbox aligned with app rows: unchecked for none, mixed for some, checked for all. Clicking unchecked/mixed selects eligible visible apps; clicking checked clears visible selections. Search scopes the bulk action and preserves hidden grants. Protected/uninstalled apps cannot gain a new bulk grant; existing visible grants can still be removed. An empty result disables the checkbox. Editing remains local until Save, and saving still requires at least one app.

Remove the count ceiling from Flutter, connection validation and persisted pairing decoding. Retain existing package-name validation and saved grants. Do not replace 64 with another arbitrary count. Share native validation so save and restore cannot diverge. No queue-size or unrelated limits change.

Verify tri-state toggling, search-only clearing, no-result state, protected/uninstalled cases and saving/restoring more than 64 apps. Submit an open PR with validation evidence; do not merge or publish a release as part of this correction.
