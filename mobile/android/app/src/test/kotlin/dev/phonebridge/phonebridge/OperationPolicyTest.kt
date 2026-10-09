package dev.phonebridge.phonebridge

import org.junit.Assert.assertEquals
import org.junit.Test

class OperationPolicyTest {
    @Test fun textEntryRequiresExplicitInputFocus() {
        denied("FOCUS_REQUIRED") { OperationPolicy.requireInputFocus(false) }
        OperationPolicy.requireInputFocus(true)
    }

    @Test fun notificationChannelMustExistAndRemainEnabled() {
        OperationPolicy.requireNotifications(true, 2)
        denied("NOTIFICATIONS_DISABLED") { OperationPolicy.requireNotifications(false, 2) }
        denied("NOTIFICATIONS_DISABLED") { OperationPolicy.requireNotifications(true, 0) }
        denied("NOTIFICATIONS_DISABLED") { OperationPolicy.requireNotifications(true, null) }
    }

    @Test fun observationsWorkInReadOnlySessions() {
        OperationPolicy.requireSession(true, true, true, true, false, false)
    }

    @Test fun everyMutationRequiresLocalConsent() {
        denied("READ_ONLY") { OperationPolicy.requireSession(true, true, true, true, false, true) }
        OperationPolicy.requireSession(true, true, true, true, true, true)
    }

    @Test fun lockingBlocksBothReadsAndActionsEvenWithConsent() {
        for (mutation in listOf(false, true)) {
            denied("DEVICE_LOCKED") { OperationPolicy.requireSession(true, true, true, false, true, mutation) }
        }
    }

    @Test fun stopStaleCallbacksAndDetachedServicesCannotUsePriorConsent() {
        for (mutation in listOf(false, true)) {
            denied("NO_SESSION") { OperationPolicy.requireSession(false, true, true, true, true, mutation) }
            denied("NO_SESSION") { OperationPolicy.requireSession(true, false, true, true, true, mutation) }
            denied("NO_SESSION") { OperationPolicy.requireSession(true, true, false, true, true, mutation) }
        }
    }

    private fun denied(code: String, action: () -> Unit) {
        try {
            action()
            throw AssertionError("Expected authorization rejection")
        } catch (error: BridgeFailure) {
            assertEquals(code, error.code)
        }
    }
}
