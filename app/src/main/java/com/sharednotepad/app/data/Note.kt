package com.sharednotepad.app.data

import com.google.firebase.Timestamp
import com.google.firebase.firestore.DocumentId
import com.google.firebase.firestore.ServerTimestamp

data class Note(
    @DocumentId val id: String = "",
    val title: String = "",
    val content: String = "",
    val pinned: Boolean = false,
    @ServerTimestamp val updatedAt: Timestamp? = null,
    val updatedBy: String? = null,
)
