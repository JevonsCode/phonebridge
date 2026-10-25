package dev.phonebridge.phonebridge

internal enum class FocusedOperationFailure {
    NO_FOCUS, FOCUS_TIMEOUT, WINDOW_UNAVAILABLE, WINDOW_ENDED,
    OPERATION_FAILED, AUTHORITY_BEFORE, AUTHORITY_AFTER, CLEANUP_FAILED,
}

/** Execute once under real window focus. Failed cleanup retains its original ownership. */
internal class FocusedOperationLifecycle<T : Any>(
    private val validate: () -> Unit,
    private val operation: () -> T,
    private val release: () -> Boolean,
    private val failure: (FocusedOperationFailure) -> BridgeFailure,
    private val complete: (T?, BridgeFailure?) -> Unit,
) {
    var finished = false
        private set
    var cleanupPending = false
        private set
    private var operating = false

    fun focused(hasWindowFocus: Boolean) {
        if (finished || operating || !hasWindowFocus) return
        operating = true
        var result: T? = null
        var error: BridgeFailure? = null
        try {
            validate()
            result = operation()
        } catch (rejected: BridgeFailure) {
            error = rejected
        } catch (_: Exception) {
            error = failure(FocusedOperationFailure.OPERATION_FAILED)
        }
        finish(result, error)
    }

    /** Revoke an outstanding focus request promptly when its original authority ends. */
    fun checkAuthority() {
        if (finished) return
        try { validate() }
        catch (failure: BridgeFailure) { fail(failure) }
        catch (_: Exception) { fail(failure(FocusedOperationFailure.AUTHORITY_BEFORE)) }
    }

    fun fail(error: BridgeFailure) = finish(null, error)

    fun retryCleanup(): Boolean {
        if (cleanupPending) cleanupPending = !tryRelease()
        return !cleanupPending
    }

    private fun tryRelease(): Boolean = try { release() } catch (_: Exception) { false }

    private fun finish(result: T?, failure: BridgeFailure?) {
        if (finished) return
        // Detachment/focus callbacks can run reentrantly during window removal.
        finished = true
        cleanupPending = !tryRelease()
        var error = failure
        if (cleanupPending && error == null) {
            error = this.failure(FocusedOperationFailure.CLEANUP_FAILED)
        }
        if (error == null) {
            try { validate() }
            catch (changed: BridgeFailure) { error = changed }
            catch (_: Exception) { error = this.failure(FocusedOperationFailure.AUTHORITY_AFTER) }
        }
        complete(if (error == null) result else null, error)
    }
}
