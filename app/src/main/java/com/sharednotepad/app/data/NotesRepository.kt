package com.sharednotepad.app.data

import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.SetOptions
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.tasks.await

/** Sort: pinned note first, then most recently updated. */
fun List<Note>.displayOrder(): List<Note> =
    sortedWith(
        compareByDescending<Note> { it.pinned }
            .thenByDescending { it.updatedAt?.toDate()?.time ?: Long.MAX_VALUE }
    )

class NotesRepository(padCode: String) {

    private val db = Firebase.firestore
    private val notesCol = db.collection(PADS).document(padCode).collection(NOTES)

    /** Live stream of all notes on the pad; updates in real time on both phones. */
    fun notesFlow(): Flow<List<Note>> = callbackFlow {
        val registration = notesCol.addSnapshotListener { snapshot, error ->
            if (error != null) {
                close(error)
                return@addSnapshotListener
            }
            if (snapshot != null) {
                trySend(snapshot.toObjects(Note::class.java).displayOrder())
            }
        }
        awaitClose { registration.remove() }
    }

    suspend fun getNote(id: String): Note? =
        notesCol.document(id).get().await().toObject(Note::class.java)

    suspend fun createNote(title: String): String {
        val ref = notesCol.document()
        ref.set(Note(title = title, updatedBy = AuthHelper.currentUid())).await()
        return ref.id
    }

    suspend fun saveNote(id: String, title: String, content: String) {
        notesCol.document(id).set(
            mapOf(
                "title" to title,
                "content" to content,
                "updatedAt" to FieldValue.serverTimestamp(),
                "updatedBy" to AuthHelper.currentUid(),
            ),
            SetOptions.merge(),
        ).await()
    }

    /** Pins one note (the one the widget shows) and unpins the rest. */
    suspend fun pinNote(id: String, allNotes: List<Note>) {
        val batch = db.batch()
        allNotes.filter { it.pinned && it.id != id }.forEach { other ->
            batch.set(notesCol.document(other.id), mapOf("pinned" to false), SetOptions.merge())
        }
        batch.set(notesCol.document(id), mapOf("pinned" to true), SetOptions.merge())
        batch.commit().await()
    }

    suspend fun unpinNote(id: String) {
        notesCol.document(id).set(mapOf("pinned" to false), SetOptions.merge()).await()
    }

    suspend fun deleteNote(id: String) {
        notesCol.document(id).delete().await()
    }

    companion object {
        private const val PADS = "pads"
        private const val NOTES = "notes"
        private const val CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        private const val CODE_LENGTH = 8

        /** Creates a new pad with a random share code and returns the code. */
        suspend fun createPad(): String {
            val db = Firebase.firestore
            while (true) {
                val code = (1..CODE_LENGTH).map { CODE_ALPHABET.random() }.joinToString("")
                val doc = db.collection(PADS).document(code)
                if (!doc.get().await().exists()) {
                    doc.set(mapOf("createdAt" to FieldValue.serverTimestamp())).await()
                    return code
                }
            }
        }

        /** Returns the normalized code if a pad with that code exists, else null. */
        suspend fun joinPad(rawCode: String): String? {
            val code = rawCode.trim().uppercase().replace(" ", "")
            if (code.length != CODE_LENGTH) return null
            val snapshot = Firebase.firestore.collection(PADS).document(code).get().await()
            return if (snapshot.exists()) code else null
        }
    }
}
