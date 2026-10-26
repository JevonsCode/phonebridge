# PhoneBridge 0.7.2

Multiple computers can stay connected to one phone and take turns controlling it. Selecting another computer on the phone now only changes the settings view: it no longer ends the active AI task or reserves the phone for 60 seconds.

- The first requesting AI controls the phone; later requests wait in FIFO order. Releasing or ending the current task lets the next waiting task continue.
- Pairing or selecting another computer does not interrupt a task, change its deadline or move another task ahead in the queue.
- Keep all remembered computers, App access and other settings when updating. The phone's computer list explains that selection and control are independent.
- Existing 0.7.1 desktop clients support this phone fix; updating or pairing the computer again is not required. Matching 0.7.2 desktop packages are also provided.

Validation: 228 Android JVM tests and 138 mobile Flutter tests passed, with clean Flutter analysis. Six assertions covering task preservation, idle-phone access, FIFO handoff and active-gesture authority failed against the old behavior and passed after the fix. The original failure was also reproduced on the existing Android 16 phone with two computers online: selecting the current settings computer caused the other computer's active workflow to return `CONTROL_EXPIRED`.

Android updates retain the existing preview signer. Mac packages are ad-hoc signed and are not Apple Developer ID notarized.
