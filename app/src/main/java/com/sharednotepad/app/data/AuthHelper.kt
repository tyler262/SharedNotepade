package com.sharednotepad.app.data

import com.google.firebase.auth.ktx.auth
import com.google.firebase.ktx.Firebase
import kotlinx.coroutines.tasks.await

object AuthHelper {
    /**
     * Signs in anonymously (once per install) so Firestore security rules
     * can require an authenticated caller. Returns the uid.
     */
    suspend fun ensureSignedIn(): String {
        val auth = Firebase.auth
        auth.currentUser?.let { return it.uid }
        val result = auth.signInAnonymously().await()
        return requireNotNull(result.user).uid
    }

    fun currentUid(): String? = Firebase.auth.currentUser?.uid
}
