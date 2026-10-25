package dev.phonebridge.phonebridge

import org.junit.Assert.*
import org.junit.Test

class OwnerEditorLifecycleTest {
    @Test fun unprotectedEditorOpeningPreservesTheTapThenAllowsObservationAndCheckboxActions() {
        val scope = SessionOperationScope()
        assertTrue(scope.begin("open-app-list"))
        val opening = scope.generation
        scope.markGestureDispatched(opening)
        val blocked = AppAccessPolicy.blocksRemote(true, false)
        assertFalse(scope.invalidateForOwnerAuthorization(blocked))
        assertTrue(scope.isCurrent(opening))
        assertFalse(scope.awaitingGestureSettlement)
        assertFalse(scope.begin("premature-checkbox"))
        assertTrue(scope.complete("open-app-list", opening))

        assertTrue(scope.begin("observe-app-list"))
        OperationPolicy.requireSession(true, scope.isCurrent(scope.generation), true, true, true, false, blocked)
        assertTrue(scope.complete("observe-app-list", scope.generation))
        assertTrue(scope.begin("toggle-checkbox"))
        OperationPolicy.requireSession(true, scope.isCurrent(scope.generation), true, true, true, true, blocked)
        assertTrue(scope.complete("toggle-checkbox", scope.generation))
    }

    @Test fun protectedEditorInvalidatesTheOldTapButRetainsItsFenceUntilCompletion() {
        val scope = SessionOperationScope()
        scope.begin("open-app-list")
        val opening = scope.generation
        scope.markGestureDispatched(opening)
        assertTrue(scope.invalidateForOwnerAuthorization(AppAccessPolicy.blocksRemote(true, true)))
        assertFalse(scope.isCurrent(opening))
        assertTrue(scope.awaitingGestureSettlement)
        assertEquals("open-app-list", scope.pending)
        assertFalse(scope.begin("other-operation"))
        assertTrue(scope.complete("open-app-list", opening))
    }

    @Test fun closingTheProtectedEditorDoesNotReviveAnAlreadyInvalidatedOperation() {
        val scope = SessionOperationScope()
        scope.begin("old")
        val generation = scope.generation
        scope.invalidateForOwnerAuthorization(AppAccessPolicy.blocksRemote(true, true))
        assertFalse(AppAccessPolicy.blocksRemote(false, true))
        assertFalse(scope.isCurrent(generation))
        assertTrue(scope.complete("old", generation))
        assertTrue(scope.begin("new-observation"))
        OperationPolicy.requireSession(true, scope.isCurrent(scope.generation), true, true, true, false,
            AppAccessPolicy.blocksRemote(false, true))
    }

    @Test fun realGrantRevocationStillInvalidatesTheOperationWhenEditorProtectionIsOff() {
        val scope = SessionOperationScope()
        scope.begin("old-grant")
        val generation = scope.generation
        scope.markGestureDispatched(generation)
        assertFalse(scope.invalidateForOwnerAuthorization(AppAccessPolicy.blocksRemote(true, false)))
        scope.invalidate()
        assertFalse(scope.isCurrent(generation))
        assertTrue(scope.awaitingGestureSettlement)
        assertFalse(scope.begin("new-grant"))
        assertTrue(scope.complete("old-grant", generation))
        assertTrue(scope.begin("new-grant"))
    }
}
